-- ============================================================
-- NAME    : PROCEDURE AUKRC1_create_OP_by_TRANSFER_LINK
-- Description    : Создание Акта переоценки на размещении аптеки по перемещению
-- Author         : vsh
-- Release        : 17.02.09
-- Changelog:
-- * 17.04.12  vsh - все переоценки (без учета связи)
-- * 21.09.12  vsh - количество не обновлялось, связь документов
-- * 22.07.12  star - учет вложенности размещений
-- * 02.06.16  star - обработка документа целиком
-- * 26.03.2020 Lukin E.V. изменен принцип взятия цены :
--                                                      1. смотрим тех таблицу (price || markup) - применяем с приоритетом price (иначе markup)
--                                                      2. партия есть на получаете - берем цену получателя
--                                                      3. партии не было на получателе - тянем цену отправителя
-- * 10.06.2020 Lukin E.V. - перенесён функционал взятия цены в процедуру "TRANSFER_BEFORE"
-- * 16.12.2021 star - цена по текущей цене партии на размещении-источнике
--                           - дата Акта - текущая
-- * 15.05.2023 star - расчет цен для аптек со спец.ценами для прихода в аптеку
--                           - цены из перемещения для расхода из аптек со спец.ценами
-- * 13.06.2024 star - расчет цен для аптек по реестру наценок
--                           - удаление расчета цен для аптек со спец.ценами
-- * 20.06.2024 star - канал продаж для расчета спец.цен
-- * 07.07.2024 star - hot fix восстановления цены при перемещении из аптеки с управляемой наценкой
-- * 11.10.2024 star  - в описании наценок добавлен параметр код службы для цен на агрегаторы
-- * 14.10.2024 star  - исключен режим проверки управлением наценки
-- * 03.12.2024 star  - fix цена берется по РЦ, если партия не была на размещении
-- * 26.12.2024 star  - Перемещение с аптеки на РЦ = если есть остаток РЦ, то переоценивать до цены на РЦ отгрузки.
-- * 24.11.2025 star - исключение LINE_NAME из LINE_TRANSFER
-- * 21.05.2026 Lukin E.V. - добавлена проверка флага @CNS_IS_SPECIAL_PRICE - для уцененных партий транслирием цену без изменения
-- ============================================================
ALTER PROCEDURE AUKRC1_create_OP_by_TRANSFER_LINK
    @id_link  T_IDENTIFIER, 
    @id_prime T_DOCUMENT_ID, 
    @id_child T_DOCUMENT_ID = NULL
AS
BEGIN
    DECLARE @message VARCHAR(300), @type_message INT, @result INT, @IRET INT, @err VARCHAR(10);

    DECLARE @LOCATION_ID        INT, @LOCATION_DEP_ID INT, 
            @LOCATION_SUBDEP_ID INT, @LOCATION_SECT_ID INT,
            @AUTHOR_ID  T_AUTHOR, 
            @CURR_HOME  T_CURRENCY_ID, @CURR_MAIN T_CURRENCY_ID,
            @NewId      INT, @SELFENTER_ID T_IDENTIFIER, 
            @DOCUM_NUMB T_DOCUMENT_NUMB, @DOCUM_DATE DATETIME, @DOCUM_STATE T_DOCUM_STATE, 
            @RATE_HOME_TO_MAIN T_CURRENCY_RATE, @tLINE_NUMBER INT, 
            @tLINE_PLU_ID      T_PLU,
            @tLINE_CNS_ID      T_CONSIGNMENT,  @tLINE_NAME T_NAME_LONG, @tLINE_UNIT T_METRIC_ID,
            @LINE_PRICE_HOME   T_COST, @LINE_PRICEFULL_HOME T_COST, 
            @LINE_PRICE_MAIN T_COST, @LINE_PRICEFULL_MAIN T_COST,
            @STOCK_PRICEFULL_MAIN T_COST, @STOCK_PRICEFULL_HOME T_COST, @STOCK_PRICE_MAIN T_COST,
            @STOCK_PRICE_HOME     T_COST, @flag INT, @TYPE_TRANSFER INT, @TYPE_OVERPRICE INT, 
            @res           INT,         @CNS_COSTFULL    MONEY, 
            @rem_id_out    VARCHAR(10), @rem_id_in       VARCHAR(10), 
            @DEPARTMENT_ID INT,         @BUILDER_ID      INT,
            @SPEC_PRICE    MONEY,       @LOCATION_ID_OUT INT,
            @USE_RC_PRICE  INT,
			@CNS_IS_SPECIAL_PRICE INT;

    SET @result = 0;
    SET @TYPE_TRANSFER = 5;
    SET @TYPE_OVERPRICE = 23;

    EXEC dbo.GET_AUTHORID @AUTHOR_ID = @AUTHOR_ID OUTPUT;

    IF @AUTHOR_ID IS NULL
    BEGIN
        SET @result = 200;
        SET @message = 'Ошибка! Не удалось определить автора для акта переоценки.';
        SET @type_message = 16;
        GOTO finish;
    END;

    SELECT @SELFENTER_ID = g.SELFENTER_ID, @DOCUM_DATE = g.DOCUM_DATE, 
           @CURR_HOME = g.DOCUM_HOME_CURR, @CURR_MAIN = g.DOCUM_MAIN_CURR, 
           @LOCATION_ID = g.OUT_LOCATION_ID, @LOCATION_DEP_ID = g.OUT_LOCATION_DEP_ID,
           @LOCATION_SUBDEP_ID = g.OUT_LOCATION_SUBDEP_ID, @LOCATION_SECT_ID = g.OUT_LOCATION_SECT_ID, 
           @DOCUM_STATE = g.DOCUM_STATE, 
           @rem_id_out = isnull(ro.REMPOINT_ID,''),  
           @rem_id_in = isnull(ri.REMPOINT_ID,''),
           @LOCATION_ID_OUT = g.LOCATION_ID
    FROM [TRANSFER] g
      LEFT JOIN REMOTE_POINT ro ON ro.LOCATION_ID = g.LOCATION_ID
                               AND (  LEFT(ro.REMPOINT_ID,1) in ('A','R')
                                   or ro.LOCATION_DEP_ID = g.LOCATION_DEP_ID)
      LEFT JOIN REMOTE_POINT ri ON ri.LOCATION_ID = g.OUT_LOCATION_ID
                               AND (  LEFT(ri.REMPOINT_ID,1) in ('A','R')
                                   or ri.LOCATION_DEP_ID = g.OUT_LOCATION_DEP_ID)
    WHERE (g.DOCUM_ID = @id_prime);

    IF (@rem_id_in LIKE 'RC%') AND (@LOCATION_ID <> @LOCATION_ID_OUT)
      SET @USE_RC_PRICE = 1
    ELSE
      SET @USE_RC_PRICE = 0;

    SET @DOCUM_DATE = GETDATE();

    EXEC @IRET = dbo.CREATE_DOC_HOME
                       @SELFENTER_ID = @SELFENTER_ID, @TDOC_ID = 23, 
                       @DOCUM_NUMB = @DOCUM_NUMB, @DOCUM_DATE = @DOCUM_DATE, 
                       @DOCUM_HOME_CURR = @CURR_HOME, @DOCUM_MAIN_CURR = @CURR_MAIN, 
                       @LOCATION_ID = @LOCATION_ID, @LOCATION_DEP_ID = @LOCATION_DEP_ID,
                       @LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID, @LOCATION_SECT_ID = @LOCATION_SECT_ID,
                       @DOCUM_STATE = 3, @AUTHOR_ID = @AUTHOR_ID,
                       @DOCUM_ID = @id_child OUTPUT;

    IF @@ERROR <> 0 OR @IRET <> 0 OR ISNULL(@id_child, 0) <= 0
    BEGIN
        SET @result = 100 + @IRET;
        SET @message = 'Ошибка! Не удалось создать новый акт переоценки.';
        SET @type_message = 16;
        GOTO finish;
    END;

    -- получаем курс на дату создания акта и вносим его в документ
    EXEC dbo.GET_RATE @DateTimeNow = @DOCUM_DATE, @CurrencyId = @CURR_HOME, 
                      @MAIN_Main = @RATE_HOME_TO_MAIN OUTPUT;

    UPDATE dbo.OVERVALUE_PRICE SET 
        ACTOVER_RATE_MAIN_TO_HOME = @RATE_HOME_TO_MAIN
      WHERE DOCUM_ID = @id_child;

    DECLARE DocLine_Cursor CURSOR READ_ONLY LOCAL FORWARD_ONLY FOR
        SELECT lt.LINE_PLU_ID, lt.LINE_CNS_ID, p.PLU_NAME, lt.LINE_UNIT, lt.LINE_NUMBER, 
          ISNULL(sc.STOCK_CN_PRICE_HOME,0),  ISNULL(sc.STOCK_CN_PRICEFULL_HOME,0),  
          ISNULL(sc.STOCK_CN_PRICE_MAIN,0),  ISNULL(sc.STOCK_CN_PRICEFULL_MAIN,0),
          ISNULL(h.HYST_CNSPR_PRICE_HOME,0), ISNULL(h.HYST_CNSPR_PRICEFULL_HOME,0), 
          ISNULL(h.HYST_CNSPR_PRICE_MAIN,0), ISNULL(h.HYST_CNSPR_PRICEFULL_MAIN,0),
          c.CNS_COSTFULL_HOME, p.DEPARTMENT_ID, p.BUILDER_ID, coalesce(c.CNS_IS_SPECIAL_PRICE, 0)
        FROM LINE_TRANSFER lt
          INNER JOIN PLU p ON p.PLU_ID = lt.LINE_PLU_ID
          INNER JOIN CONSIGNMENT c ON c.CNS_ID = lt.LINE_CNS_ID
          LEFT JOIN STOCK_CONSIGNMENT sc ON sc.PLU_ID = lt.LINE_PLU_ID
                                        AND sc.CNS_ID = lt.LINE_CNS_ID
                                        AND sc.LOCATION_ID        = lt.LINE_LOC_ID
                                        AND sc.LOCATION_DEP_ID    = lt.LINE_DEP_ID
                                        AND sc.LOCATION_SUBDEP_ID = lt.LINE_SUBDEP_ID
                                        AND sc.LOCATION_SECT_ID   = lt.LINE_SECT_ID
          LEFT JOIN HYST_CNS_PRICE h ON h.PLU_ID = lt.LINE_PLU_ID
                                    AND h.CNS_ID = lt.LINE_CNS_ID
                                    AND h.LOCATION_ID        = @LOCATION_ID
                                    AND h.LOCATION_DEP_ID    = @LOCATION_DEP_ID
                                    AND h.LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID
                                    AND h.LOCATION_SECT_ID   = @LOCATION_SECT_ID
                                    AND h.HYST_CNSPR_DT      < @DOCUM_DATE
                                    AND h.NEXT_CNSPR_DT      >=@DOCUM_DATE
        WHERE lt.DOCUM_ID = @id_prime
        ORDER BY lt.LINE_NUMBER;

    OPEN DocLine_Cursor;

    WHILE (1=1)
    BEGIN
        FETCH NEXT FROM DocLine_Cursor
          INTO @tLINE_PLU_ID,     @tLINE_CNS_ID, @tLINE_NAME, @tLINE_UNIT, @tLINE_NUMBER,
               @LINE_PRICE_HOME,  @LINE_PRICEFULL_HOME,  @LINE_PRICE_MAIN,  @LINE_PRICEFULL_MAIN, 
               @STOCK_PRICE_HOME, @STOCK_PRICEFULL_HOME, @STOCK_PRICE_MAIN, @STOCK_PRICEFULL_MAIN,
               @CNS_COSTFULL,     @DEPARTMENT_ID,        @BUILDER_ID, @CNS_IS_SPECIAL_PRICE;
        if(@@FETCH_STATUS <> 0)
          break;

        IF NOT EXISTS ( SELECT 1 FROM dbo.STOCK
            WHERE PLU_ID = @tLINE_PLU_ID
                  AND LOCATION_ID = @LOCATION_ID
                  AND LOCATION_DEP_ID = @LOCATION_DEP_ID
                  AND LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID
                  AND LOCATION_SECT_ID = @LOCATION_SECT_ID
        )
        BEGIN
            EXEC @result = dbo.INSERT_STOCK_BY_PLU @PLU_ID = @tLINE_PLU_ID, @LOCATION_ID = @LOCATION_ID,
                                                   @LOCATION_DEP_ID = @LOCATION_DEP_ID,
                                                   @LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID,
                                                   @LOCATION_SECT_ID = @LOCATION_SECT_ID;
            IF (@@ERROR <> 0)
               OR (@result <> 0)
            BEGIN
                SET @result = 7;
                SET @message = 'Ошибка добавления карточки товара!';
                BREAK;
            END;
        END;

        IF @tLINE_CNS_ID IS NOT NULL
           AND NOT EXISTS ( SELECT 1 FROM dbo.STOCK_CONSIGNMENT
            WHERE CNS_ID = @tLINE_CNS_ID
                  AND PLU_ID = @tLINE_PLU_ID
                  AND LOCATION_ID = @LOCATION_ID
                  AND LOCATION_DEP_ID = @LOCATION_DEP_ID
                  AND LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID
                  AND LOCATION_SECT_ID = @LOCATION_SECT_ID
        )
        BEGIN
            INSERT INTO dbo.STOCK_CONSIGNMENT (
                PLU_ID, CNS_ID, LOCATION_ID, LOCATION_DEP_ID, 
                LOCATION_SUBDEP_ID, LOCATION_SECT_ID, STOCK_CN_DOC_DATE
            )
            VALUES
                 (@tLINE_PLU_ID, @tLINE_CNS_ID, @LOCATION_ID, @LOCATION_DEP_ID,
                  @LOCATION_SUBDEP_ID, @LOCATION_SECT_ID, @DOCUM_DATE);
            IF (@@ERROR <> 0)
            BEGIN
                SET @result = 7;
                SET @message = 'Ошибка создания партии на размещении приема при перемещении!';
                BREAK;
            END;
        END;

        EXEC @IRET = dbo.ADD_LINE_OVERPRICE 
                            @DOCUM_ID = @id_child, @LINE_NUMBER = @tLINE_NUMBER,
                            @LINE_PLU_ID = @tLINE_PLU_ID, @LINE_CNS_ID = @tLINE_CNS_ID,
                            @LINE_NAME = @tLINE_NAME, @LINE_UNIT = @tLINE_UNIT,
                            @LINE_PRICE_HOME     = @LINE_PRICE_HOME,
                            @LINE_PRICEFULL_HOME = @LINE_PRICEFULL_HOME,
                            @LINE_PRICE_MAIN     = @LINE_PRICE_MAIN,
                            @LINE_PRICEFULL_MAIN = @LINE_PRICEFULL_MAIN,
                            @LINE_OLD_RETAIL_HOME     = @STOCK_PRICE_HOME,
                            @LINE_OLD_RETAILFULL_HOME = @STOCK_PRICEFULL_HOME,
                            @LINE_OLD_RETAIL_MAIN     = @STOCK_PRICE_MAIN,
                            @LINE_OLD_RETAILFULL_MAIN = @STOCK_PRICEFULL_MAIN,
                            @LINE_LOC_ID = @LOCATION_ID, @LINE_DEP_ID = @LOCATION_DEP_ID,
                            @LINE_SUBDEP_ID = @LOCATION_SUBDEP_ID, @LINE_SECT_ID = @LOCATION_SECT_ID,
                            @LINE_QUAN = 0, @LINE_QUAN_DISTRIB = 0, @NewId = @NewId OUTPUT;

        IF @@ERROR <> 0
           OR @IRET < 0
           OR @NewId IS NULL
        BEGIN
            SET @result = 100 + @IRET;
            SET @message = 'Ошибка! Не удалось добавить новую строку в акт переоценки.';
            SET @type_message = 16;
            BREAK;
        END;

        SET @SPEC_PRICE = @LINE_PRICEFULL_HOME;
        -- проверка управлением наценки
        -- ..есть ли управление наценкой на размещении приема
        IF (@USE_RC_PRICE = 0) AND
           ( EXISTS(select 1 FROM CM_MARGIN_REGISTER r 
               WHERE r.PLU_ID = @tLINE_PLU_ID
                 AND r.SALES_CHANNEL = 0
                 AND (r.REMPOINT_ID IS NULL OR r.REMPOINT_ID = @rem_id_in)) OR
             EXISTS(select 1 FROM CM_MARGIN_REGISTER r 
               WHERE r.DEPARTMENT_ID = @DEPARTMENT_ID
                 AND r.SALES_CHANNEL = 0
                 AND (r.REMPOINT_ID IS NULL OR r.REMPOINT_ID = @rem_id_in)) OR
             (   @BUILDER_ID IS NOT NULL
             AND EXISTS(select 1 FROM CM_MARGIN_REGISTER r 
                 WHERE r.BUILDER_ID = @BUILDER_ID
                   AND r.SALES_CHANNEL = 0
                   AND (r.REMPOINT_ID IS NULL OR r.REMPOINT_ID = @rem_id_in)))
          )
        BEGIN
          -- есть управление наценкой
          SET @SPEC_PRICE = dbo.CM_CALC_APT_MARGIN_PRICE( 
                                   @rem_id_in,           @tLINE_PLU_ID,
                                   @LINE_PRICEFULL_HOME, @CNS_COSTFULL, 0, 0 );
        END
        -- ..есть ли управление наценкой на размещении отгрузки
        ELSE IF ((@USE_RC_PRICE = 1)
                OR
                ( EXISTS(select 1 FROM CM_MARGIN_REGISTER r 
                       WHERE r.PLU_ID = @tLINE_PLU_ID
                         AND r.SALES_CHANNEL = 0
                         AND (r.REMPOINT_ID IS NULL OR r.REMPOINT_ID = @rem_id_out)) OR
                   EXISTS(select 1 FROM CM_MARGIN_REGISTER r 
                       WHERE r.DEPARTMENT_ID = @DEPARTMENT_ID
                         AND r.SALES_CHANNEL = 0
                         AND (r.REMPOINT_ID IS NULL OR r.REMPOINT_ID = @rem_id_out)) OR
                   (   @BUILDER_ID IS NOT NULL
                   AND EXISTS(select 1 FROM CM_MARGIN_REGISTER r 
                       WHERE r.BUILDER_ID = @BUILDER_ID
                         AND r.SALES_CHANNEL = 0
                         AND (r.REMPOINT_ID IS NULL OR r.REMPOINT_ID = @rem_id_out)))
                )
                OR (@SPEC_PRICE = 0))
        BEGIN
			-- цена - по РЦ
			SELECT @SPEC_PRICE = sc.STOCK_CN_PRICEFULL_HOME
			FROM STOCK_CONSIGNMENT sc 
			INNER JOIN REMOTE_POINT r ON r.LOCATION_ID = sc.LOCATION_ID AND LEFT(r.REMPOINT_ID,1) ='R'
			WHERE sc.PLU_ID = @tLINE_PLU_ID
				AND sc.CNS_ID = @tLINE_CNS_ID
				AND sc.LOCATION_DEP_ID = 1  -- отгрузки   			         
        END
		
		-- цена переоценки
		if @CNS_IS_SPECIAL_PRICE = 1
		begin			
			--select TOP 1 @SPEC_PRICE = lop.LINE_PRICEFULL_HOME
			--from LINE_OVERVALUE_PRICE lop
			--where lop.LINE_CNS_ID = @tLINE_CNS_ID and lop.LINE_LOC_ID = 1 and lop.LINE_DEP_ID = 3 and lop.LINE_DONE = 1
			--order by lop.DOCUM_ID desc
			SELECT @SPEC_PRICE = sc.STOCK_CN_PRICEFULL_HOME
			FROM STOCK_CONSIGNMENT sc 
			INNER JOIN REMOTE_POINT r ON r.LOCATION_ID = sc.LOCATION_ID --AND LEFT(r.REMPOINT_ID,1) ='R'
			WHERE sc.PLU_ID = @tLINE_PLU_ID 
				AND sc.CNS_ID = @tLINE_CNS_ID
				and sc.LOCATION_ID = @LOCATION_ID and sc.LOCATION_DEP_ID = @LOCATION_DEP_ID  -- отгрузка
				
		end
        
        if(@SPEC_PRICE <> @LINE_PRICEFULL_HOME)
        begin
          exec COST_SALE_FACT
              @plu       = @tLINE_PLU_ID,
              @operation = 4, -- ввод цены @retailfull_h 
              @rate_to_home = 1,
              @rate_to_main = @RATE_HOME_TO_MAIN,
              @id_home      = @CURR_HOME,
              @id_main      = @CURR_MAIN,
              @id_currency  = @CURR_HOME,
              @retail_h     = @LINE_PRICE_HOME     OUTPUT,
              @retailfull_h = @LINE_PRICEFULL_HOME OUTPUT,
              @retail_m     = @LINE_PRICE_MAIN     OUTPUT,
              @retailfull_m = @LINE_PRICEFULL_MAIN OUTPUT,
              @retail       = @LINE_PRICE_HOME     OUTPUT,
              @retailfull   = @LINE_PRICEFULL_HOME OUTPUT,
              @new_value    = @SPEC_PRICE;

          update LINE_OVERVALUE_PRICE set
               LINE_PRICE_HOME      = @LINE_PRICE_HOME
              ,LINE_PRICEFULL_HOME  = @LINE_PRICEFULL_HOME
              ,LINE_PRICE_MAIN      = @LINE_PRICE_MAIN
              ,LINE_PRICEFULL_MAIN  = @LINE_PRICEFULL_MAIN
              ,LINE_OVERPRICE_DISCOUNT = case when isnull(@STOCK_PRICEFULL_HOME,0) = 0 then 0
                 else (@LINE_PRICEFULL_HOME - @STOCK_PRICEFULL_HOME) * 100./@STOCK_PRICEFULL_HOME end
              ,LINE_OVERPRICE_INCOUNT  = case when isnull(@CNS_COSTFULL,0) = 0 then 0
                 else (@LINE_PRICEFULL_HOME - @CNS_COSTFULL) * 100./@CNS_COSTFULL end
            where LINE_ID = @NewId

        end
    END;
    CLOSE DocLine_Cursor;
    DEALLOCATE DocLine_Cursor;

    IF @result <> 0
        GOTO finish; 
    -- Конец блока заполнения документа -------------------------------------

--   -- уточняется в процедуре обработки Акта
--   -- пересчет суммы документа
--   exec @IRET = CALC_DOC_SUMM_FOR_OverPrice

    -- связь
    INSERT INTO dbo.LINK_DOC (
        LINKDOC_MAIN_TYPE, LINKDOC_MAIN_ID, LINKDOC_DEPEND_TYPE, LINKDOC_DEPEND_ID )
      VALUES
         (@TYPE_TRANSFER, @id_prime, @TYPE_OVERPRICE, @id_child );
    IF @@Error <> 0
    BEGIN
        SET @result = 13; 
        SET @message = 'Ошибка установки связи между счетом и актом';
        SET @type_message = 16;
    END;

    -- обработка
    EXEC @IRET = dbo.CLOSE_LINE_OVERPRICE @docum_id = @id_child;

    IF @@ERROR <> 0 OR @IRET <> 0
    BEGIN
        SET @result = 100 + @IRET;
        SET @message = 'Ошибка! Не удалось  обработать акта пероценки';
        SET @type_message = 16;
    END;

    finish:

    UPDATE #link_temp
    SET RESULT   = @result
      , id_prime = @id_prime
      , id_child = @id_child
      , MESSAGE  = @message
      , type_message = @type_message
    WHERE id_link = @id_link;

    RETURN @result;
END;
----------------------------------------------------------
GO
