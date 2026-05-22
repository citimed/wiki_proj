IF OBJECT_ID('GIN_AFTER') IS NOT NULL
  DROP PROCEDURE GIN_AFTER
GO

-- ==========================================================
-- Procedure: dbo.GIN_AFTER
-- Author: machok
-- Realise: 2023.02.06 (дата создания)
-- Description: процесс после обработки ПТО
--
-- Changelog:
-- 18.03.2023 star - доработка
-- 16.05.2023 machok - проверка прихода товара Блок 5
-- 23.06.2023 star - фикс создания связанного перемещения (блок 4)
-- 15.07.2023 star - rename for block 5
-- 10.01.2024 star - проверка и обновление папки перенесено в before
-- 30.09.2024 star - Обработки кода мориона, кода поставщика, УКТЗЭД и штрих-кода (через вызов CM_GIN_UPDATE_PLU)
-- 26.10.2025 star - замена очередности переоценки и закрытия заказов поставщикам
-- 06.05.2026 star - расчет средней скользящей учетной цены для артикулов в ПТО
-- ==========================================================

CREATE PROCEDURE GIN_AFTER
  @DOCUM_ID T_IDENTIFIER,            -- код документа
  @MESSAGE  VARCHAR(240) = '' OUTPUT -- сообщение
AS 
DECLARE
  @result int;
SET @result  = 0
SET @message = ''

declare
  @DOCEXTGOODS_CREDIT_TERMS datetime, 
  @ENTERPRISE_GCRD_DAYS     int,
  @ENTERPRISE_GCRD_PERMIT   tinyint,
  @ENTERPRISE_ID            varchar(10),
  @GIN_DATE                 DATETIME,
  @DOCEXTGOODS_DATE_COMMIT  datetime,
  @DOCUM_EXTCOMMENT   varchar(250),
  @ENTERPRISE_COD     varchar(12),
  @LOCATION_ID        int,
  @LOCATION_DEP_ID    INT, 
  @LOCATION_SUBDEP_ID INT, 
  @LOCATION_SECT_ID   INT,
  @GIN_COMMENT        INT,
  @DOCUM_STATE        INT,
  @GIN_PLU_ID      VARCHAR (15),
  @GIN_QTY         MONEY,
  @GIN_PRICE       MONEY,
  @GIN_LINE_ID     INT,          
  @ORDER_DOCUM_ID  INT,
  @ORDER_ENTERPRISE_ID  T_ENTERPRISE_ID,
  @ORDER_DATE      INT,
  @ORDER_QTY       MONEY,        
  @ORDER_QTY_DONE  MONEY, 
  @ORDER_LINE_ID   INT,          
  @DONE_QTY        MONEY,
  @ANALOG_GROUP_ID INT,
  @MIN_DATE        DATE,
  @COST_LINE_ID    INT,
  @COST_AVG        MONEY


SELECT @DOCEXTGOODS_CREDIT_TERMS = g.DOCEXTGOODS_CREDIT_TERMS,       
       @ENTERPRISE_ID            = g.ENTERPRISE_ID,
       @GIN_DATE                 = g.DOCUM_DATE,
       @DOCEXTGOODS_DATE_COMMIT  = g.DOCEXTGOODS_DATE_COMMIT,
       @LOCATION_ID              = g.LOCATION_ID, 
       @LOCATION_DEP_ID          = g.LOCATION_DEP_ID,
       @LOCATION_SUBDEP_ID       = g.LOCATION_SUBDEP_ID,
       @LOCATION_SECT_ID         = g.LOCATION_SECT_ID, 
       @GIN_COMMENT              = g.COMMENT,
       @DOCUM_EXTCOMMENT         = g.DOCUM_EXTCOMMENT,
       @DOCUM_STATE              = g.DOCUM_STATE,
       @ENTERPRISE_COD           = ISNULL(LTRIM(e.ENTERPRISE_COD),''),
       @ENTERPRISE_GCRD_DAYS     = ENTERPRISE_GCRD_DAYS,
       @ENTERPRISE_GCRD_PERMIT   = ENTERPRISE_GCRD_PERMIT
  from GIN g
    inner join ENTERPRISE e ON g.ENTERPRISE_ID = e.ENTERPRISE_ID
  where DOCUM_ID = @DOCUM_ID;

IF isnull(@DOCUM_STATE,0) < 5
  return 0;

-- BLOCK 1 ---------------------------------------------------------- 
BEGIN TRY
BEGIN TRANSACTION

--BIF01_GIN_SET_CREDIT_TERMS
IF (@DOCEXTGOODS_DATE_COMMIT IS NULL)
BEGIN
  SET @DOCEXTGOODS_DATE_COMMIT = GETDATE();

  UPDATE GIN SET 
      DOCEXTGOODS_DATE_COMMIT = @DOCEXTGOODS_DATE_COMMIT
    WHERE DOCUM_ID = @DOCUM_ID;
END

IF @DOCEXTGOODS_CREDIT_TERMS IS NULL AND
   @ENTERPRISE_GCRD_PERMIT = 1 AND 
   @ENTERPRISE_GCRD_DAYS   > 0
BEGIN
  UPDATE GIN SET 
     DOCEXTGOODS_CREDIT_TERMS = dateadd(d, @ENTERPRISE_GCRD_DAYS, @GIN_DATE ),
     DOCEXTGOODS_CREDIT_TERMS_DAY = @ENTERPRISE_GCRD_DAYS
   WHERE DOCUM_ID = @DOCUM_ID
END
--BIF01_GIN_SET_CREDIT_TERMS

--LINKPROCESS_GIN_CHECK_EDRPOU
if charindex(' ',@DOCUM_EXTCOMMENT) > 1 and 
    ISNUMERIC(substring(@DOCUM_EXTCOMMENT, 1, charindex(' ',@DOCUM_EXTCOMMENT)-1)) = 1
begin
  SET @ENTERPRISE_COD = substring(@DOCUM_EXTCOMMENT, 1, charindex(' ',@DOCUM_EXTCOMMENT)-1)
  
  IF NOT EXISTS(SELECT 1 FROM ENTERPRISE
            WHERE ENTERPRISE_ID  = @ENTERPRISE_ID
              AND ENTERPRISE_COD = @ENTERPRISE_COD)
     AND @ENTERPRISE_COD <>'38184267' 
     and @ENTERPRISE_COD <>'39189025'
  begin
    UPDATE ENTERPRISE
      SET ENTERPRISE_COD = @ENTERPRISE_COD
    WHERE ENTERPRISE_ID = @ENTERPRISE_ID
  end   
end
--LINKPROCESS_GIN_CHECK_EDRPOU

--LINKPROCESS_GIN_SETBARCODE
DECLARE @SUPPLIER_ID  varchar(15),
  @CNS_ID       int,
  @LOT_DOC_ID   T_IDENTIFIER,
  @PLU_ID       T_PLU,   
  @LINE_ID      T_IDENTIFIER,
  @NewBarCode   varchar(80)

select @SUPPLIER_ID = ENTERPRISE_ID
  from gin
  where DOCUM_ID = @DOCUM_ID
  
DECLARE crBarcod INSENSITIVE CURSOR FOR
  SELECT l.LINE_ID, l.LINE_PLU_ID, l.LINE_CNS_ID, lot.LOT_DOC_ID
    FROM LINE_GIN l
      LEFT JOIN CONSIGNMENT c ON (l.LINE_CNS_ID = c.CNS_ID )
      LEFT JOIN LOT lot ON l.LINE_ID = lot.LOT_DOCLINE_ID 
                       AND lot.LOT_DOC_TYPE = 14
    WHERE l.DOCUM_ID = @DOCUM_ID
      and l.LINE_TYPE = 0
      and ltrim(rtrim(isnull(CASE WHEN c.CNS_ID IS NOT NULL 
            THEN c.CNS_BARCOD ELSE lot.LOT_BARCOD END,''))) = ''
    ORDER BY l.LINE_NUMBER

OPEN crBarcod
WHILE (1 = 1)
BEGIN
  FETCH NEXT FROM crBarcod INTO @LINE_ID, @PLU_ID, @CNS_ID, @LOT_DOC_ID
  IF @@FETCH_STATUS <> 0
    BREAK  

  set @NewBarCode=''
  exec GET_NEW_BARCODE  @IsPiece = 2, @NewBarCode = @NewBarCode output
  if (@@error <> 0)
  begin
    set @message = 'Ошибка генерации штрих-кода для артикула '+ @PLU_ID
    RAISERROR(@message,16,1)
    break    
  end
  if (isnull(@NewBarCode,'')='')
  begin
    set @message = 'Пустой штрих-код для артикула '+ @PLU_ID
    RAISERROR(@message,16,1)
    break    
  end
  if @CNS_ID is not null
  begin
    UPDATE CONSIGNMENT SET CNS_BARCOD = @NewBarCode
      WHERE CNS_ID = @CNS_ID
    if (@@error <> 0)
    begin
      set @message = 'Ошибка записи штрих-кода для артикула '+ @PLU_ID
      RAISERROR(@message,16,1)
      break    
    end    
  end
  else
  begin    
    if @LOT_DOC_ID is null -- создаем партию
    begin
      SELECT top 1 @CNS_ID = c.CNS_ID
       FROM CONSIGNMENT c
          WHERE c.PLU_ID = @PLU_ID
            AND c.ENTERPRISE_ID = @SUPPLIER_ID
          order by c.cns_doc_date desc
      if(@CNS_ID is not null)
      begin
        exec LOT_CREATE_BY_CNS
          @DOCTYPE            = 14, 
          @DOCLINEID          = @LINE_ID,
          @DOCID              = @docum_id,
          @CNS_ID             = @CNS_ID
      end
      else
      begin
        INSERT INTO LOT (LOT_DOCLINE_ID, LOT_DOC_TYPE, LOT_DOC_ID, LOT_PLU_ID,
                         LOT_ENTERPRISE_ID )
                 VALUES (@LINE_ID, 14, @docum_id, @PLU_ID, @SUPPLIER_ID )
      end
      if (@@error <> 0)
      begin
        set @message = 'Ошибка создания прототипа партии для артикула '+ @PLU_ID
        RAISERROR(@message,16,1)
        break    
      end
    end 
    UPDATE LOT SET LOT_BARCOD = @NewBarCode
        WHERE LOT_DOCLINE_ID = @LINE_ID
          AND LOT_DOC_TYPE = 14
    if (@@error <> 0)
    begin
      set @message = 'Ошибка обновления прототипа партии для артикула '+ @PLU_ID
      RAISERROR(@message,16,1)
      break    
    end
  end    
END
CLOSE crBarcod
DEALLOCATE crBarcod    
--LINKPROCESS_GIN_SETBARCODE

COMMIT TRANSACTION
SET @result = 0;

END TRY  -- block 1
begin CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
  SET @MESSAGE = 'Блок 1, ошибка:'+char(13)+char(10)
               + ERROR_MESSAGE()
  --SET @Result=1
  return 1;  -- Блок 1, ошибка
END CATCH

-- BLOCK 3 ----------------------------------------------------------
-- замена очередности переоценки и закрытия заказов поставщикам 
BEGIN TRY
BEGIN TRANSACTION
  --BIF01_GIN_CR_OVP_AND_TRANSF
    DECLARE @link_transfer INT,  @link_overprice INT,
            @id_child            INT, @OUT_LOCATION_ID INT, 
            @OUT_LOCATION_DEP_ID INT, @rempoint VARCHAR(5);

    SET @link_overprice = 14015;

    EXEC @result = dbo.LINK_DOC_CONTROL_CENTER @id_prime = @DOCUM_ID, @id_child = @id_child OUTPUT,
                                               @id_link = @link_overprice, @t_prime = 14, @t_child = 23;

    IF @@ERROR <> 0 OR @result <> 0 OR ISNULL(@id_child, 0) <= 0
    BEGIN
      RAISERROR('Ошибка создания акта переоценки.',16,1)
    END;

    EXEC @result = dbo.CLOSE_LINE_OVERPRICE @docum_id = @id_child;
    IF @@ERROR <> 0
       OR @result <> 0
    BEGIN
      RAISERROR('Ошибка обработки акта переоценки.',16,1)
    END;

COMMIT TRANSACTION
SET @result = 0;

END TRY  -- block 3
begin CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
  SET @MESSAGE = 'Блок 3, ошибка создания переоценки по ПТО:'+char(13)+char(10)
               + ERROR_MESSAGE()
  return 3;  -- Блок 3, ошибка
END CATCH

-- BLOCK 7 ----------------------------------------------------------
-- расчет средней скользящей учетной цены для артикулов в ПТО

BEGIN TRY
  BEGIN TRANSACTION
  -- по артикулам
  DECLARE cost_20260427 CURSOR FAST_FORWARD READ_ONLY LOCAL FOR
    SELECT l.LINE_PLU_ID
         , SUM(l.LINE_QUAN) 
         , SUM(l.LINE_QUAN * l.LINE_PRICEFULL_HOME) / SUM(l.LINE_QUAN) 
      FROM LINE_GIN l
      WHERE l.DOCUM_ID = @DOCUM_ID
      GROUP BY l.LINE_PLU_ID;
  
  OPEN cost_20260427;  
  WHILE (1=1)
  BEGIN
  	FETCH NEXT FROM cost_20260427 
      INTO @GIN_PLU_ID, @GIN_QTY, @GIN_PRICE;
    IF (@@FETCH_STATUS <> 0) 
      BREAK;
  
  -- считаем
  EXEC CM_COST_AVG_CALC
        @PLU_ID    = @GIN_PLU_ID
      , @CALC_DT   = @DOCEXTGOODS_DATE_COMMIT
      , @NEW_QTY   = @GIN_QTY
      , @NEW_COST  = @GIN_PRICE
      , @COST_AVG  = @COST_AVG  OUTPUT

  -- пишем в историю
  EXEC CM_COST_AVG_INSERT
        @PLU_ID   = @GIN_PLU_ID    -- артикул
      , @COST_DT  = @DOCEXTGOODS_DATE_COMMIT      -- дата расчета цены
      , @DOC_TYPE = 14             -- тип документа, по которому рассчитывалась цена
      , @DOC_ID   = @DOCUM_ID      -- код документа, ***
      , @COST_AVG = @COST_AVG      -- цена скользящая средняя учетная   
  END
  CLOSE cost_20260427;
  DEALLOCATE cost_20260427;

  COMMIT TRANSACTION
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
--  SET @MESSAGE = 'Блок 7, расчет средней скользящей учетной для артикулов:'+char(13)+char(10)
--               + ERROR_MESSAGE()
END CATCH

-- BLOCK 2 ----------------------------------------------------------
-- замена очередности переоценки и закрытия заказов поставщикам
BEGIN TRY
BEGIN TRANSACTION
--_CLOSE_PURCHASE_ORDER_BY_GIN

SET @MIN_DATE = DATEADD( mm, -4, GETDATE())

DECLARE @orders TABLE
(
    ORDER_DOCUM_ID      INT,
    ORDER_LOCATION_ID   INT,
    ORDER_ENTERPRISE_ID T_ENTERPRISE_ID,
    ORDER_DATE          datetime
);

-- получим все активные заказы 
INSERT INTO @orders 
  ( ORDER_DOCUM_ID, ORDER_LOCATION_ID, ORDER_ENTERPRISE_ID, ORDER_DATE)
-- приход на аптеку и конкретный поставщик
SELECT po.DOCUM_ID, po.LOCATION_ID, po.ENTERPRISE_ID, po.DOCUM_DATE
    FROM dbo.REMOTE_POINT rp
    JOIN dbo.PURCHASE_ORDER po ON
                                po.ENTERPRISE_ID = @ENTERPRISE_ID -- NOT IN ( '-1', '-2' )
                                AND po.LOCATION_ID = rp.LOCATION_ID
                                AND po.DOCUM_STATE < 5
                                AND po.DOCUM_DATE > @MIN_DATE
                                AND po.IS_PAPER = 1
                                AND po.LIABILITY_CLEARDISTRIB_DT IS NOT NULL
    WHERE rp.LOCATION_ID = @LOCATION_ID
      AND (PATINDEX('A%', rp.REMPOINT_ID) > 0 AND PATINDEX('A0', rp.REMPOINT_ID) = 0 )
UNION ALL
-- приход на аптеку и технический поставщик
SELECT po.DOCUM_ID, po.LOCATION_ID, po.ENTERPRISE_ID, po.DOCUM_DATE
    FROM dbo.REMOTE_POINT rp
    JOIN dbo.PURCHASE_ORDER po ON
                                (po.ENTERPRISE_ID = '-1')
                                AND po.LOCATION_ID = rp.LOCATION_ID
                                AND po.DOCUM_STATE < 5
                                AND po.DOCUM_DATE > @MIN_DATE
                                AND po.IS_PAPER = 1
                                AND po.LIABILITY_CLEARDISTRIB_DT IS NOT NULL
    WHERE rp.LOCATION_ID = @LOCATION_ID
      AND (PATINDEX('A%', rp.REMPOINT_ID) > 0 AND PATINDEX('A0', rp.REMPOINT_ID) = 0 )
UNION ALL
-- приход не на аптеку и конкретный поставщик
SELECT po.DOCUM_ID, po.LOCATION_ID, po.ENTERPRISE_ID, po.DOCUM_DATE
    FROM dbo.REMOTE_POINT rp
    JOIN dbo.PURCHASE_ORDER po ON
                                po.ENTERPRISE_ID = @ENTERPRISE_ID -- NOT IN ( '-1', '-2' )
                                AND po.LOCATION_ID = rp.LOCATION_ID
                                AND po.DOCUM_STATE < 5
                                AND po.DOCUM_DATE > @MIN_DATE
                                -- AND po.IS_PAPER = 1
                                AND po.LIABILITY_CLEARDISTRIB_DT IS NOT NULL
    WHERE rp.LOCATION_ID IN (
              SELECT rp2.LOCATION_ID FROM dbo.REMOTE_POINT rp2 
                WHERE PATINDEX('АПТЕКА%', rp2.REMPOINT_NAME) = 0 )
      AND @LOCATION_ID IN (
              SELECT rp2.LOCATION_ID FROM dbo.REMOTE_POINT rp2 
                WHERE PATINDEX('АПТЕКА%', rp2.REMPOINT_NAME) = 0 )
UNION ALL
-- приход не на аптеку и технический поставщик
SELECT po.DOCUM_ID, po.LOCATION_ID, po.ENTERPRISE_ID, po.DOCUM_DATE
    FROM dbo.REMOTE_POINT rp
    JOIN dbo.PURCHASE_ORDER po ON
                                (po.ENTERPRISE_ID = '-1')
                                AND po.LOCATION_ID = rp.LOCATION_ID
                                AND po.DOCUM_STATE < 5
                                AND po.DOCUM_DATE > @MIN_DATE
                                AND po.IS_PAPER = 1
                                AND po.LIABILITY_CLEARDISTRIB_DT IS NOT NULL
    WHERE rp.LOCATION_ID IN (
              SELECT rp2.LOCATION_ID FROM dbo.REMOTE_POINT rp2 
                WHERE PATINDEX('АПТЕКА%', rp2.REMPOINT_NAME) = 0 )
      AND @LOCATION_ID IN (
              SELECT rp2.LOCATION_ID FROM dbo.REMOTE_POINT rp2 
                WHERE PATINDEX('АПТЕКА%', rp2.REMPOINT_NAME) = 0 );

DECLARE cr_gin CURSOR FAST_FORWARD READ_ONLY LOCAL FOR
    SELECT LINE_ID, LINE_PLU_ID, LINE_QUAN, a.ANALOG_GROUP_ID
      FROM LINE_GIN l
        LEFT JOIN PLU_ANALOG a ON a.PLU_ID = l.LINE_PLU_ID
      WHERE DOCUM_ID = @DOCUM_ID;

OPEN cr_gin;
WHILE (1=1)
BEGIN
  FETCH NEXT FROM cr_gin
    INTO @GIN_LINE_ID, @GIN_PLU_ID, @GIN_QTY, @ANALOG_GROUP_ID;
  if(@@FETCH_STATUS != 0)
    break;

  DECLARE cr_order CURSOR FAST_FORWARD READ_ONLY LOCAL FOR
    SELECT o.ORDER_DOCUM_ID, o.ORDER_ENTERPRISE_ID, l.LINE_ID, 
           l.LINE_QUAN,      isnull(l.ORDSU_L_QUAN,0)
        FROM LINE_PURCHASE_ORDER l
          inner join @orders o on o.ORDER_DOCUM_ID = l.DOCUM_ID
          LEFT JOIN PLU_ANALOG a ON a.PLU_ID = l.LINE_PLU_ID
        WHERE l.LINE_DONE = 0
          and (  l.LINE_PLU_ID = @GIN_PLU_ID
              OR ISNULL(a.ANALOG_GROUP_ID,-1)
                              = ISNULL(@ANALOG_GROUP_ID,-2) )
          and l.LINE_QUAN - isnull(l.ORDSU_L_QUAN,0) > 0
        ORDER BY o.ORDER_DATE;

  OPEN cr_order;
  WHILE (@GIN_QTY > 0)
  BEGIN
      FETCH NEXT FROM cr_order
        INTO @ORDER_DOCUM_ID, @ORDER_ENTERPRISE_ID, @ORDER_LINE_ID, 
              @ORDER_QTY,      @ORDER_QTY_DONE;
      if(@@FETCH_STATUS != 0)
        break;

      set @DONE_QTY = @ORDER_QTY - @ORDER_QTY_DONE;

      -- если закрываем больше или равно, чем в заказе.
      IF @GIN_QTY >= @DONE_QTY
      BEGIN
          -- установим поле "поставлено кол-во"
          UPDATE dbo.LINE_PURCHASE_ORDER
            SET ORDSU_L_QUAN = @ORDER_QTY
          WHERE LINE_ID = @ORDER_LINE_ID;

          -- закроем строку заказа
          EXEC dbo.CLOSE_LINE_PURCHASEORD
                    @docum_id = @ORDER_DOCUM_ID, @line_id = @ORDER_LINE_ID;

          set @GIN_QTY = @GIN_QTY - @DONE_QTY;
      END
      else -- если закрываем меньше, чем в заказе. Тогда дробим строку заказа.
      -- IF @GIN_QTY < @ORDER_QTY
      BEGIN
          -- установим поле "поставлено кол-во"
          UPDATE dbo.LINE_PURCHASE_ORDER
            SET ORDSU_L_QUAN = isnull(ORDSU_L_QUAN,0) + @GIN_QTY
          WHERE LINE_ID = @ORDER_LINE_ID;

          set @ORDER_QTY = @GIN_QTY
          set @GIN_QTY = 0;
      END;
      -- запишем в линковочную таблицу
      if(@ORDER_ENTERPRISE_ID IN ( '-1', '-2' ))
      begin
        INSERT INTO dbo._LINK_GIN_PURCHASE_ORDER 
              ( LINE_GIN_ID, LINE_PRUCHASE_ORDER_ID, PLU_ID, QTY )
            VALUES
              ( @GIN_LINE_ID, @ORDER_LINE_ID, @GIN_PLU_ID, @ORDER_QTY );
      end

      if not exists(select 1 from LINK_DOC  
                        where LINKDOC_MAIN_TYPE   = 9 
                          AND LINKDOC_MAIN_ID     = @ORDER_DOCUM_ID
                          AND LINKDOC_DEPEND_TYPE = 14
                          AND LINKDOC_DEPEND_ID   = @DOCUM_ID )
        insert into LINK_DOC
            ( LINKDOC_MAIN_TYPE, LINKDOC_MAIN_ID, 
              LINKDOC_DEPEND_TYPE, LINKDOC_DEPEND_ID )
          values ( 9, @ORDER_DOCUM_ID, 14, @DOCUM_ID );
  END;

  CLOSE cr_order;
  DEALLOCATE cr_order;

  if(@GIN_QTY > 0)
  begin
      set @ORDER_LINE_ID = NULL;

      SELECT top 1 @ORDER_DOCUM_ID = o.ORDER_DOCUM_ID, @ORDER_LINE_ID = l.LINE_ID
        FROM LINE_PURCHASE_ORDER l
          inner join @orders o on o.ORDER_DOCUM_ID = l.DOCUM_ID
        WHERE l.LINE_PLU_ID = @GIN_PLU_ID
        order by o.ORDER_DATE desc;

      if(@ORDER_LINE_ID is not null)
      begin
          -- добавим излишек
          UPDATE dbo.LINE_PURCHASE_ORDER
            SET ORDSU_L_QUAN = isnull(ORDSU_L_QUAN,0) + @GIN_QTY
          WHERE LINE_ID = @ORDER_LINE_ID;

          if not exists(select 1 from LINK_DOC  
                            where LINKDOC_MAIN_TYPE   = 9 
                              AND LINKDOC_MAIN_ID     = @ORDER_DOCUM_ID
                              AND LINKDOC_DEPEND_TYPE = 14
                              AND LINKDOC_DEPEND_ID   = @DOCUM_ID )
            insert into LINK_DOC
                ( LINKDOC_MAIN_TYPE, LINKDOC_MAIN_ID, 
                  LINKDOC_DEPEND_TYPE, LINKDOC_DEPEND_ID )
              values ( 9, @ORDER_DOCUM_ID, 14, @DOCUM_ID );
      end;
  end;
END;

CLOSE cr_gin;
DEALLOCATE cr_gin;
--_CLOSE_PURCHASE_ORDER_BY_GIN

COMMIT TRANSACTION
SET @result = 0;

END TRY  -- block 2
begin CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
  SET @MESSAGE = 'Блок 2, ошибка обработки заказов поставщикам:'+char(13)+char(10)
               + ERROR_MESSAGE()
  --SET @Result=1
  return 2;  -- Блок 2, ошибка
END CATCH

-- BLOCK 5 ----------------------------------------------------------
-- проверки прихода товара по заказу аптек
BEGIN TRY
  BEGIN TRANSACTION

  exec @result = CM_PHARM_ORDER_CHECK_GIN @DOCUM_ID

  IF @result <> 0 
  BEGIN
      RAISERROR('Ошибка проверки заказов клиентов',16,1)
  END;
  COMMIT TRANSACTION
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
  SET @MESSAGE = 'Блок 5, проверки прихода товара по заказу аптек:'+char(13)+char(10)
               + ERROR_MESSAGE()
  return 5;  -- Блок 5, ошибка
END CATCH

-- BLOCK from 3 to 4 ------------------------------------------------
-- проверка необходимости создания перемещения
IF (@GIN_COMMENT = 4) -- ПТО без автоматики
BEGIN
  GOTO finish_BIF01_GIN_CR_OVP_AND_TRANSF;
END;

-- получим адрес объекта
set @rempoint ='';
SELECT @rempoint = ISNULL(r.REMPOINT_ID,'')
  FROM dbo.REMOTE_POINT r 
  WHERE r.LOCATION_ID = @LOCATION_ID
    AND (  r.REMPOINT_ID LIKE 'RC%' OR r.REMPOINT_ID LIKE 'A%' 
        OR r.LOCATION_DEP_ID = @LOCATION_DEP_ID);

-- если это аптека
IF (@rempoint like 'A%')
BEGIN
  SELECT @OUT_LOCATION_ID = @LOCATION_ID, -- куда
         @OUT_LOCATION_DEP_ID = 2;
END
ELSE IF @LOCATION_ID = 36   -- создание перемещения временно отключено для РЦ2
BEGIN
  GOTO finish_BIF01_GIN_CR_OVP_AND_TRANSF;
END;

--пропускаем только ПТО на РЦ-обменный или Аптека-склад
IF NOT (  (@rempoint like 'RC%' AND @LOCATION_DEP_ID=2)
       OR (@rempoint like 'A%' AND @LOCATION_DEP_ID=1) )
  GOTO finish_BIF01_GIN_CR_OVP_AND_TRANSF;

-- BLOCK 4 ----------------------------------------------------------
BEGIN TRY
BEGIN TRANSACTION
    SET @link_transfer = 14032;

    EXEC @result = dbo.LINK_DOC_CONTROL_CENTER 
                         @id_prime = @DOCUM_ID, @id_child = @id_child OUTPUT,
                         @id_link = @link_transfer, @t_prime = 14, @t_child = 5;

    IF @@ERROR <> 0 OR @result <> 0
    BEGIN
      RAISERROR('Ошибка формирования перемещения.',16,1)
    END;

    UPDATE dbo.TRANSFER SET
        OUT_LOCATION_ID = @LOCATION_ID, -- куда
        OUT_LOCATION_DEP_ID = CASE WHEN @LOCATION_ID IN ( 34, 36 ) THEN 1
                                   ELSE @OUT_LOCATION_DEP_ID END, 
        OUT_LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID,
        OUT_LOCATION_SECT_ID = @LOCATION_SECT_ID, 
        DOCUM_DATE = GETDATE(), 
        DOCUM_STATE = 3
      WHERE DOCUM_ID = @id_child;

    EXECUTE @result = dbo.CALC_DOC_SUMM_FOR_TRANSFER @DOCUM_ID = @id_child;

    IF (@@error <> 0) OR (@result <> 0)
    BEGIN
      RAISERROR('Ошибка при пересчете суммы перемещения',16,1)
    END;

    -- для аптеки склад-касса = обрабатываем
    -- для РЦ обменный-отгрузки = НЕ обрабатываем
    -- если аптека, тогда проведем
    IF (@rempoint like 'A%') AND (@OUT_LOCATION_DEP_ID = 2)
    BEGIN
      EXEC @result = dbo.CLOSE_LINE_TRANSFER @DOCUM_ID = @id_child;

      IF (@result <> 0)
      BEGIN
        RAISERROR('Не удалось закрыть накладную на перемещение',16,1)
      END;
    END
    ELSE
    BEGIN
      --если перемещение склад обменный - отгрузка, тогда блокируем 
      UPDATE dbo.TRANSFER SET COMMENT = 15
        WHERE DOCUM_ID = @id_child;
    END;

COMMIT TRANSACTION
SET @result = 0;

END TRY
begin CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
  SET @MESSAGE = 'Блок 4, ошибка создания перемещения:'+char(13)+char(10)
               + ERROR_MESSAGE()
  return 4;  -- Блок 4, ошибка
END CATCH

finish_BIF01_GIN_CR_OVP_AND_TRANSF:
--BIF01_GIN_CR_OVP_AND_TRANSF

-- BLOCK 6 ----------------------------------------------------------
-- Привязки артикула
BEGIN TRY
  BEGIN TRANSACTION

  EXEC @result = CM_GIN_UPDATE_PLU
          @ID_PRIME = @DOCUM_ID,
          @MESSAGE  = @MESSAGE OUTPUT;
  IF (@result <> 0)
  BEGIN
    RAISERROR( @MESSAGE, 16,1)
  END;

  COMMIT TRANSACTION
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0  
    ROLLBACK TRANSACTION
  SET @MESSAGE = 'Блок 6, Привязки артикула:'+char(13)+char(10)
               + ERROR_MESSAGE()
  return 6;  -- Блок 6, ошибка
END CATCH

finish_plu_link:

RETURN @Result;
----
GO

GRANT EXECUTE ON GIN_AFTER TO ROLE_TWAPP
GO