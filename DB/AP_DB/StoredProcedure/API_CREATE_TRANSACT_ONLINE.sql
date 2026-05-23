IF OBJECT_ID('dbo.API_CREATE_TRANSACT_ONLINE') IS NOT NULL
    DROP PROCEDURE dbo.API_CREATE_TRANSACT_ONLINE;
GO

----------------------------------------------------------
-- NAME   : PROCEDURE API_CREATE_TRANSACT_ONLINE
-- NOTE   : REST online создание чека от таблеток в аптеке
-- CREATE : 29.11.2021 Lukin E.V.
-- ALTER  : 17.12.2021 Lukin E.V. -  при синхронизации(@SYNC_ONLY = 1) отметим как синхронизированные все 
--          предшестующие статусы для заказа(statusID <= @statusID AND syncStatus = 0)
-- ALTER  : 14.02.2022 Lukin E.V. - исправлено округление при приведении типов CONVERT(VARCHAR(20),@qtyShip)
--                                 на CONVERT(VARCHAR(20),CONVERT(NUMERIC(15, 3), @qtyShip))
-- ALTER  : 15.02.2022 Lukin E.V. - добавлено условие отбора для синхронизации l.statusID IN ( 2, 3, 4, 6, 7 ) 
--                                  сместо l.statusID IN ( 2, 3, 4, 6 )
-- ALTER  : 14.04.2022 Lukin E.V. - увеличена длина поля "row_string" с 200 до 8000
-- ALTER  : 25.04.2022 Lukin E.V. - увеличена длина переменной @result_string с 200 до 8000
-- ALTER  : 12.05.2022 Lukin E.V. - убрано поле row_string, теперь получение строк идет отдельным запросом из API
-- ALTER  : 24.05.2022 Lukin E.V. - Добавлена проверка на заказы от LIKI24
-- ALTER  : 22.07.2022 Lukin E.V. - отформатирована дата и убраны ##
-- RELEASE: 01.02.2024 star - запись предприятия при создании от Таблетки и Лики
-- ALTER  : 20.02.2024 Lukin E.V. - автоматически подтвердим готовность заказа, если смогли создать чек
--                  - обновим поэтапно, чтобы использовать текущий механизм без изменений
-- ALTER  : 28.02.2024 Lukin E.V. - получим уже проверенное(округление до целого вверх) кол-во через классификатор и сохраним
-- ALTER  : 05.03.2024 Lukin E.V. - вернём обработку кол-ва и цену как было, проверку через классификатор делаем в ЦБД
-- ALTER  : 07.03.2024 Lukin E.V. - добавлено фактическое кол-во при подтверждении. Так же учитывается, если СКЮ в классификаторе.
-- ALTER  : 11.03.2024 Lukin E.V. - добавлена фактическая цена priceShip, при подтверждении.
-- ALTER  : 23.05.2024 Lukin E.V. - убрали проверку хелсчек
-- ALTER  : 12.09.2024 Lukin E.V. - Интеграция с агрегатором liki.ua
-- RELEASE: 24.10.2024 star - инфо по остаткам в случае отказа (только для TabletkiUA)
-- ALTER  : 01.11.2024 Lukin E.V. - инфо по остаткам в случае отказа для TabletkiUA и LIKI24, так же курсор сделан локальным
-- RELEASE: 09.12.2024 star - hot fix обработки результата распределения
-- RELEASE: 09.12.2024 star - оптимизация в заполнении чека
-- ALTER  : 03.02.2025 Lukin E.V. - фактическое распределение в чек
-- ALTER  : 04.02.2025 Lukin E.V. - автоматически добавим дисконткарту к чеку если телефон не '+38 (044) 000%'
--									- проверка классификатора/онлайн делимость теперь при подборе партий
-- ALTER  : 18.02.2025 Lukin E.V. - добавлены поля qtyDistrib и priceDistrib для фиксации кол-ва и цены автоматического подтверждения
-- RELEASE: 06.02.2026 star - учет онлайн делимости, если она описана для артикула
-- RELEASE: 10.02.2026 star - отмена ***
----------------------------------------------------------
CREATE PROCEDURE dbo.API_CREATE_TRANSACT_ONLINE
  @SYNC_ONLY INT          = 0,
  @MESSAGE   NVARCHAR(max) = '' OUTPUT  -- инфо по остаткам в случае отказа
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE
      @USER_NAME VARCHAR(100), 
      @MONUS_ID  INT, 
      @MONUS_DT  DATETIME,
      @DO_CANCEL INT;

    SET @MESSAGE = '';
    SET @DO_CANCEL = 0;

    IF OBJECT_ID('tempdb..#docs_temp') IS NULL
        CREATE TABLE #docs_temp
        (
            DOCUM_TYPE           INT            NULL,
            DOCUM_ID             INT            NULL,
            DOCUM_DATE           DATETIME       NULL,
            DOCUM_STATE          INT            NULL,
            DOCUM_NUMB           VARCHAR(15)    NULL,
            AGREE_ID             INT            NULL,
            DOCUM_SUMM_HOME      MONEY          NULL,
            DOCUM_SUMM_MAIN      MONEY          NULL,
            DOC_EXT_CURR_D       INT            NULL,
            DOC_EXT_SUMM_D       MONEY          NULL,
            ENTERPRISE_ID        VARCHAR(10)    NULL,
            SELFENTER_ID         INT            NULL,
            DOCUM_AUTHOR_ID      INT            NULL,
            DOC_EXT_RATE_TO_MAIN DECIMAL(19, 9) NULL,
            DOC_EXT_RATE_TO_HOME DECIMAL(19, 9) NULL,
            row_number           INT            IDENTITY PRIMARY KEY
        );

    DECLARE @id            UNIQUEIDENTIFIER, @code INT, @statusID INT, @dateTimeCreated DATETIME, @customer NVARCHAR(100),
            @customerPhone NVARCHAR(20), @customerEmail NVARCHAR(100), @branchID NVARCHAR(10),
            @externalNmb   NVARCHAR(100), @docAdditionalInfo NVARCHAR(100), @customerAdditionalInfo NVARCHAR(100),
            @reserveSource NVARCHAR(100), @transact_id INT, @goodsCode NVARCHAR(15), @goodsName NVARCHAR(80),
            @goodsProducer NVARCHAR(40), 
			@qty MONEY, @price MONEY, @qtyShip MONEY, @priceShip MONEY,
			@stock_distr MONEY, @stock_free MONEY, @DISCARD_ID int;

    -- таблица статусов для возврата
    DECLARE @result_tbl TABLE
    (
        id            UNIQUEIDENTIFIER,
        statusId      INT,
        transact_id   INT,
        tech_error    INT
            DEFAULT 0,
        branchID      NVARCHAR(10),
        row_string    VARCHAR(8000)
            DEFAULT '',
        cancelReason  NVARCHAR(100),
        transact_numb VARCHAR(15)
    );


    IF @SYNC_ONLY = 1
    BEGIN
        ------------------------------------
        --пробуем обработать синхронизацию
        DECLARE cr_sync CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT
                   t.id, t.statusID
            FROM #api_lines_list t;

        OPEN cr_sync;

        FETCH NEXT FROM cr_sync
        INTO @id, @statusID;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;
                --сделаем псевдосинхронизацию
                UPDATE dbo._RESERVED_SALES_HEADER_LOG
                SET syncStatus = 1, syncDateTime = GETDATE()
                WHERE id = @id
                      AND statusID <= @statusID
                      AND syncStatus = 0 and statusID >= 0 ;
                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
				set @MESSAGE = ERROR_MESSAGE();

                IF @@TRANCOUNT > 0
                    ROLLBACK TRANSACTION;
            END CATCH;

            FETCH NEXT FROM cr_sync
            INTO @id, @statusID;
        END;

        CLOSE cr_sync;
        DEALLOCATE cr_sync;
    --пробуем обработать синхронизацию
    ------------------------------------------------------------
    END;

    IF @SYNC_ONLY = 0
    BEGIN
        ------------------------------------
        --пробуем обработать отказы клиентов
        DECLARE cr_refused CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT
                   t.id, t.transact_id, t.branchID
            FROM #api_lines_list t
            WHERE t.statusId = 7;

        OPEN cr_refused;

        FETCH NEXT FROM cr_refused
        INTO @id, @transact_id, @branchID;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;

                IF @transact_id > 0
                BEGIN
                    -- add into monitoring
                    EXEC dbo.REGISTER_USER_BEGIN @USER_ID = 13, @MONUS_ID = @MONUS_ID OUTPUT;

                    EXEC dbo.REGISTER_DOC_BEGIN @MONUS_ID = @MONUS_ID, @MONDOCS_TYPE = 33, @MONDOCS_ID = @transact_id,
                                                @MONUS_DT = @MONUS_DT OUTPUT, @USER_NAME = @USER_NAME OUTPUT,
                                                @MONDOCS_STATE = 0;

                    -- установим причину отказа
                    UPDATE dbo.TRANSACT
                    SET DOCUM_EXTCOMMENT = DOCUM_EXTCOMMENT + 'CODE=1'
                    WHERE DOCUM_ID = @transact_id;

                    EXEC dbo.REGISTER_DOC_END @MONDOCS_TYPE = 33, @MONDOCS_ID = @transact_id;
                    EXEC dbo.REGISTER_USER_DELETE @MONUS_ID = @MONUS_ID;


                    --удалим чек
                    EXEC dbo.DELETE_DOCUMENT @TDOC_ID = 33, @DOCUM_ID = @transact_id;
                    --сделаем псевдосинхронизацию
                    UPDATE dbo._RESERVED_SALES_HEADER_LOG
                    SET syncStatus = 1, syncDateTime = GETDATE()
                    WHERE id = @id
                          AND statusID = 7;

                    --сохраним статус для возврата
                    INSERT INTO @result_tbl (
                        id, statusId, transact_id, branchID
                    )
                    SELECT @id, -1, 0, @branchID;
                END;

                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0
                    ROLLBACK TRANSACTION;
            END CATCH;

            FETCH NEXT FROM cr_refused
            INTO @id, @transact_id, @branchID;
        END;

        CLOSE cr_refused;
        DEALLOCATE cr_refused;
        --пробуем обработать отказы клиентов
        ------------------------------------------------------------
       
	   --пробуем обработать заказы клиентов
        DECLARE cr_orders CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT
                   id, code, statusID, dateTimeCreated, customer, customerPhone, customerEmail, branchID, externalNmb,
                   docAdditionalInfo, customerAdditionalInfo, reserveSource
            FROM #api_lines_list t
            WHERE t.statusId = 2;

        OPEN cr_orders;

        FETCH NEXT FROM cr_orders
        INTO @id, @code, @statusID, @dateTimeCreated, @customer, @customerPhone, @customerEmail, @branchID,
             @externalNmb, @docAdditionalInfo, @customerAdditionalInfo, @reserveSource;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                BEGIN TRANSACTION;
                -- если есть запись в резервах, но нет чека, тогда удалим
                IF EXISTS ( SELECT 1 FROM dbo._RESERVED_SALES_HEADER h
                    LEFT JOIN dbo.TRANSACT t ON t.DOCUM_ID = h.transact_id
                    WHERE h.id = @id
                      AND h.statusID < 7
                      AND t.DOCUM_ID IS NULL
                )
                BEGIN
                    DELETE FROM dbo._RESERVED_SALES_ROWS       WHERE header_id = @id;
                    DELETE FROM dbo._RESERVED_SALES_HEADER_LOG WHERE id = @id;
                    DELETE FROM dbo._RESERVED_SALES_HEADER     WHERE id = @id;
                END;

                INSERT INTO dbo._RESERVED_SALES_HEADER (
                    id, code, statusID, dateTimeCreated, customer, customerPhone, customerEmail, branchID, externalNmb,
                    docAdditionalInfo, customerAdditionalInfo, reserveSource, cancelReason, transact_id
                )
                VALUES (@id,                     -- id - uniqueidentifier
                        @code,                   -- code - int
                        0,                       -- statusID - decimal(5, 0)
                        @dateTimeCreated,        -- dateTimeCreated - datetime
                        @customer,               -- customer - nvarchar(100)
                        @customerPhone,          -- customerPhone - nvarchar(20)
                        @customerEmail,          -- customerEmail - nvarchar(100)
                        @branchID,               -- branchID - nvarchar(10)
                        @externalNmb,            -- externalNmb - nvarchar(100)
                        @docAdditionalInfo,      -- docAdditionalInfo - nvarchar(100)
                        @customerAdditionalInfo, -- customerAdditionalInfo - nvarchar(100)
                        @reserveSource,          -- reserveSource - nvarchar(100)
                        N'',                     -- cancelReason - nvarchar(100)
                        0                        -- transact_id - int
                    );

                -------------------------------------------------------
                --заполним строки резерва
                INSERT INTO dbo._RESERVED_SALES_ROWS 
                      (header_id, goodsCode, goodsName, goodsProducer, qty, price, qtyShip, priceShip)
                SELECT @id, t.goodsCode, t.goodsName, t.goodsProducer, t.qty, t.price, t.qtyShip, t.priceShip
                  FROM #api_lines_list t
                  WHERE t.id = @id
                -------------------------------------------------------

                SET @transact_id = 0;
                --проверим техническую смену
                IF NOT EXISTS (SELECT 1 FROM dbo.SHIFT s WHERE s.SHIFT_ID = -1)
                BEGIN
                    SET IDENTITY_INSERT dbo.SHIFT ON;
                    INSERT INTO dbo.SHIFT (
                        SHIFT_ID, TR_CASH_ID, SHIFT_DT_OPEN, SHIFT_DT_CLOSE, SHIFT_AUTHOR_OPEN, SHIFT_AUTHOR_CLOSE,
                        SHIFT_DONE
                    )
                    VALUES (-1, 1, '2001-01-01 00:00:00.001', '2001-01-01 00:00:00.001', 172, 172, 1);
                    SET IDENTITY_INSERT dbo.SHIFT OFF;
                END;

                --пробуем создать закголовок чека
                DECLARE @TR_CASH_ID INT, @SHIFT_ID INT;
                SET @TR_CASH_ID = 1;
                SET @SHIFT_ID = COALESCE(
                        ( SELECT s.SHIFT_ID 
                           FROM dbo.SHIFT s 
                             WHERE s.SHIFT_DT_CLOSE IS NULL 
                               AND s.TR_CASH_ID = @TR_CASH_ID
                        ), -1 );

                EXEC dbo.CREATE_DOC_TRANSACTION @POS_ID = @TR_CASH_ID, @AUTHOR_ID = 13, @SHIFT_ID = @SHIFT_ID,
                                                @DOCUM_ID = @transact_id OUTPUT;

                --если удачно создали заголовок
                DECLARE @DOCUM_SUMM_HOME MONEY = 0.00;
                
                IF @transact_id > 0
                BEGIN
                    --добавим документ в мониторинг
                    EXEC dbo.REGISTER_USER_BEGIN @USER_ID = 13, @MONUS_ID = @MONUS_ID OUTPUT;

                    EXEC dbo.REGISTER_DOC_BEGIN @MONUS_ID = @MONUS_ID, @MONDOCS_TYPE = 33,
                                                @MONDOCS_ID = @transact_id, @MONUS_DT = @MONUS_DT OUTPUT,
                                                @USER_NAME = @USER_NAME OUTPUT, @MONDOCS_STATE = 0;

                    --обновим описание документа
					-- ALTER  : 22.07.2022 Lukin E.V. - отформатирована дата и убраны ##
                    UPDATE dbo.TRANSACT SET
                        DOCUM_BASIS = @reserveSource + ' Заказ - ' + CONVERT(VARCHAR(50), @code) + ' / '
                                    + @customerPhone + ' / ' + CONVERT(VARCHAR(50), @dateTimeCreated, 21) + '/',
                        DOCUM_EXTCOMMENT = CASE WHEN @reserveSource = 'TabletkiUA' 
                                                    THEN 'CO#TABL#'
                                                WHEN @reserveSource = 'LIKI24' 
                                                    THEN 'CO#LIKI24#'
                                                ELSE '' END + CONVERT(VARCHAR(50), @code) + '#234',
                        ENTERPRISE_ID = CASE WHEN @reserveSource = 'TabletkiUA'
                                                THEN '2534' -- ТАБЛЕТКИ-УА
                                                WHEN @reserveSource = 'LIKI24' 
                                                THEN '3299' -- Лики-24
                                                ELSE ENTERPRISE_ID END 
                    WHERE DOCUM_ID = @transact_id;

                    DECLARE @CNS_ID INT, @LINE_ID INT;

                    DECLARE cr_api_line CURSOR FAST_FORWARD LOCAL READ_ONLY FOR
                      select qty, goodsCode, price
                        from _RESERVED_SALES_ROWS
                        where header_id =@id
                    OPEN cr_api_line;

                    FETCH NEXT FROM cr_api_line
                    INTO @qty, @goodsCode, @price;

                    WHILE @@fetch_status = 0
                    BEGIN
                        -------------------------------------------
                        --подберём партии
                        DECLARE cr_line CURSOR FAST_FORWARD LOCAL READ_ONLY FOR
                            SELECT CNS_ID, PRICE, QTY
                            FROM dbo._CNS_FOR_WRITTING_OFF(@qty, @goodsCode, @price);
                        OPEN cr_line;

                        FETCH NEXT FROM cr_line
                        INTO @CNS_ID, @price, @qty;

                        WHILE @@FETCH_STATUS = 0
                        BEGIN
                            DECLARE @res INT;
                            EXEC @res = dbo.ADD_LINE_TRANSACT
                                  @DOCUM_ID    = @transact_id,
                                  @LINE_PLU_ID = @goodsCode,
                                  @LINE_QUAN   = @qty,
                                  @LINE_CNS_ID = @CNS_ID,
                                  @LINE_IN_OUT = -1,
                                  @LINE_LOC_ID = 1,
                                  @LINE_ID     = @LINE_ID OUTPUT;

                            EXEC @res = dbo.CALC_LINE_TRANSACT 
                                   @line_id  = @LINE_ID,
                                   @mode     = 505,
                                   @newValue = @price;

                            FETCH NEXT FROM cr_line
                            INTO @CNS_ID, @price, @qty;
                        END;

                        CLOSE cr_line;
                        DEALLOCATE cr_line;
                        --подберём партии
                        -------------------------------------------

                        FETCH NEXT FROM cr_api_line
                        INTO @qty, @goodsCode, @price;
                    END;

                    CLOSE cr_api_line;
                    DEALLOCATE cr_api_line;

                    EXEC dbo.CALC_SUMM_TRANSACT 
                                 @DOCUM_ID = @transact_id, 
                                 @DOCUM_SUMM_HOME = @DOCUM_SUMM_HOME OUTPUT;
                END;

                --если не смогли добавить товар в чек
                IF COALESCE(@DOCUM_SUMM_HOME, 0.00) = 0.00
                BEGIN
                    --удалим чек
                    EXEC dbo.DELETE_DOCUMENT @TDOC_ID = 33, @DOCUM_ID = @transact_id;

                    --установим причину "нехватка товара"
                    UPDATE dbo._RESERVED_SALES_HEADER
                      SET cancelReason = 'CODE=5', statusID = 7
                      WHERE id = @id;

                    SET @DO_CANCEL = 1;
                END
                ELSE
                BEGIN
					--************************************************************************************
					-- подтвердим фактическое распределение товара 
					-- проверка классификатора/онлайн делимость теперь при подборе партий
					with tbl_trans as (
							SELECT 
								lt.LINE_PLU_ID as plu_id, 
								SUM(lt.LINE_QUAN) AS qty,
								lt.LINETRANS_PRICEFULL AS price
							FROM dbo.LINE_TRANSACTION lt
							WHERE lt.DOCUM_ID = @transact_id
							GROUP BY lt.LINE_PLU_ID, lt.LINETRANS_PRICEFULL
							)
					update r set 
						r.qtyShip = t.qty,
						r.priceShip = t.price,
						r.qtyDistrib = t.qty,
						r.priceDistrib = t.price
					from _RESERVED_SALES_ROWS r 
					join tbl_trans t on t.plu_id = r.goodsCode
					where r.header_id = @id
            
					--если не могли распределить товар, тогда удалим
					if coalesce((select sum(r.qtyShip) from _RESERVED_SALES_ROWS r where r.header_id = @id), 0) = 0
					begin
						--удалим чек
						EXEC dbo.DELETE_DOCUMENT @TDOC_ID = 33, @DOCUM_ID = @transact_id;

						--установим причину "нехватка товара"
						UPDATE dbo._RESERVED_SALES_HEADER
							SET cancelReason = 'CODE=5', statusID = 7
							WHERE id = @id;

						SET @DO_CANCEL = 1;
					end
					else
					begin
						insert into [_RESERVED_SALES_HEADER_LOG](id, statusID, dateTimeCreated, syncStatus)
						values(@id, -1, getdate(), 0);
            
						UPDATE dbo._RESERVED_SALES_HEADER
						SET transact_id = @transact_id, statusID = 2
						WHERE id = @id;
            
						-- автоматически подтвердим готовность заказа
						-- обновим поэтапно, чтобы использовать текущий механизм без изменений
						UPDATE dbo._RESERVED_SALES_HEADER
						SET transact_id = @transact_id, statusID = 3
						WHERE id = @id;

						UPDATE dbo._RESERVED_SALES_HEADER
						SET transact_id = @transact_id, statusID = 4
						WHERE id = @id;

						-- временная засечка 
						INSERT INTO dbo.TRANSACT_CO (
							DOCUM_ID, DOCUM_DATE
						)
						VALUES
							(@transact_id,  -- DOCUM_ID - int
							GETDATE() -- DOCUM_DATE - datetime
							); 
							
						--***************************************
						--begin проверим на дисконткарту
							--если карты нет, тогда создадим
							-- если телефон реального клиента
							if PATINDEX('+38 (044) 000%', @customerPhone ) = 0 
							begin
								set @DISCARD_ID = null;
								set @customerPhone = rtrim(replace(replace(replace(replace(@customerPhone, ' ', ''),'(',''), ')',''), '-',''));

								select @DISCARD_ID = dc.DISCARD_ID from DISCOUNT_CARD dc where dc.PHONE like('%'+ @customerPhone +'%')

								if @DISCARD_ID is null
								begin									
									exec dbo.CM_DC_UPDATE @MODE = 0, @PHONE = @customerPhone, @APPEAL = 'уточните обращение', @DISCARD_ID = @DISCARD_ID output, @MESSAGE = @MESSAGE output;			
								end

								update TRANSACT set DISCARD_ID = @DISCARD_ID where DOCUM_ID = @transact_id;
							end
						--end проверим на дисконткарту
						--***************************************
					end
					--************************************************************************************
                END;

                EXEC dbo.REGISTER_DOC_END @MONDOCS_TYPE = 33, @MONDOCS_ID = @transact_id;
                EXEC dbo.REGISTER_USER_DELETE @MONUS_ID = @MONUS_ID;

                -----------------------------------------------------------------------
                IF(@DO_CANCEL =1) AND (@reserveSource ='TabletkiUA' or @reserveSource = 'LIKI24')
                BEGIN
                  -- детализируем остатки для инфо про отказ
                  SET @MESSAGE +='@$$$'+ CAST(@code AS varchar(20)) +';'+ CONVERT(VARCHAR(10), GETDATE(), 104)
                               +' '+ CONVERT(VARCHAR(5), GETDATE(), 108);
                  
                  DECLARE stock_20241024_Cursor CURSOR FAST_FORWARD LOCAL READ_ONLY FOR
                    SELECT LTRIM(RTRIM(t.goodsCode)), t.qty, ISNULL(s.STOCK_QUAN_DISTRIB,0), ISNULL(s.STOCK_QUAN_FREE,0)
                      FROM #api_lines_list t
                        LEFT JOIN STOCK s ON s.PLU_ID = t.goodsCode
                      WHERE t.id = @id;
      
                  OPEN stock_20241024_Cursor
                  WHILE (1 = 1)
                  BEGIN
                    FETCH NEXT FROM stock_20241024_Cursor 
                      INTO @goodsCode, @qty, @stock_distr, @stock_free;      
                    IF @@FETCH_STATUS != 0
                      BREAK;
                    SET @MESSAGE +='@==='+ @goodsCode +';'+ CAST(@qty AS VARCHAR(10))
                                  +';'+ CAST(@stock_distr AS VARCHAR(10)) +';'+ CAST(@stock_free AS VARCHAR(10));
                    IF(@stock_distr > 0)
                    BEGIN
                      ;WITH list
                      AS (
                        SELECT dtype = CASE d.STOCK_DISTR_DOC_TYPE
                                         WHEN 33 THEN 'ЧЕК'
                                         WHEN 43 THEN 'ВОЗВ.НАКЛ.'
                                         ELSE '' END
                             , dnumb = CASE d.STOCK_DISTR_DOC_TYPE 
                                         WHEN 33 THEN t.DOCUM_NUMB
                                         WHEN 43 THEN s.DOCUM_NUMB
                                         ELSE '' END
                             , qty_distr = d.STOCKCONS_DISTR_QUAN
                             , dbasis = ISNULL(CASE WHEN d.STOCK_DISTR_DOC_TYPE = 33
                                      THEN t.DOCUM_BASIS
                                    WHEN d.STOCK_DISTR_DOC_TYPE = 43
                                      THEN s.DOCUM_BASIS END, '')                           
                          FROM STOCKCONS_DISTRIB d
                            LEFT JOIN TRANSACT t ON d.STOCK_DISTR_DOC_TYPE =33
                                                AND d.STOCKCONS_DISTR_DOC_ID = t.DOCUM_ID
                            LEFT JOIN SALE s ON d.STOCK_DISTR_DOC_TYPE = 43 
                                            AND d.STOCKCONS_DISTR_DOC_ID = s.DOCUM_ID
                          WHERE d.PLU_ID = @goodsCode
                      )
                      SELECT @MESSAGE = @MESSAGE + '@###'+ dtype +';'+ LTRIM(RTRIM(dnumb))
                                       +';'+ CAST(sum(qty_distr) AS VARCHAR(10)) +';'+ LTRIM(RTRIM(dbasis))
                        FROM list
                        GROUP BY dtype, dnumb, dbasis;
                    END      
                  END
                  CLOSE stock_20241024_Cursor
                  DEALLOCATE stock_20241024_Cursor
                END  -- (@DO_CANCEL =1)
                -----------------------------------------------------------------------
                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0
                    ROLLBACK TRANSACTION;

                INSERT INTO @result_tbl (
                    id, statusId, transact_id, tech_error, branchID
                )
                VALUES (@id, 2, 0, 1, @branchID);
            END CATCH;

            FETCH NEXT FROM cr_orders
            INTO @id, @code, @statusID, @dateTimeCreated, @customer, @customerPhone, @customerEmail, @branchID,
                 @externalNmb, @docAdditionalInfo, @customerAdditionalInfo, @reserveSource;
        END;
        CLOSE cr_orders;
        DEALLOCATE cr_orders;
    ---------------------------------------------------------------------------------------------------
    END;
    -------------------------

    --получим новые статусы
    INSERT INTO @result_tbl (
        id, statusId, transact_id, branchID, cancelReason, transact_numb
    )
    SELECT l.id, l.statusID, h.transact_id, h.branchID, COALESCE(h.cancelReason, ''), RTRIM(t.DOCUM_NUMB) AS DOCUM_NUMB
    FROM dbo._RESERVED_SALES_HEADER_LOG l
    JOIN dbo._RESERVED_SALES_HEADER h ON h.id = l.id
                                         AND h.reserveSource IN ( 'LIKI24', 'TabletkiUA' )
                                         AND (
                                             (
                                                 h.transact_id = 0
                                                 AND l.statusID IN ( 0, 7 )
                                             )
                                             OR (
                                                 h.transact_id > 1
                                                 AND l.statusID IN ( 2, 3, 4, 6, 7 )
                                             )
                                             OR h.transact_id = -999
                                         )
    LEFT JOIN dbo.TRANSACT t ON t.DOCUM_ID = h.transact_id
    WHERE l.syncStatus = 0 and l.statusID >= 0;

    SELECT t.id, t.statusId, t.transact_id, t.transact_numb, t.tech_error, t.branchID, t.cancelReason
     FROM @result_tbl t
     ORDER BY t.statusId ASC;

    RETURN 0;
END;
GO

GRANT EXECUTE ON dbo.API_CREATE_TRANSACT_ONLINE TO role_TWapp;
GO
