IF OBJECT_ID('CM_SRRO_SELL', 'P') IS NOT NULL
    DROP PROCEDURE CM_SRRO_SELL;
GO

--------------------------------------------------------
-- NAME   : PROCEDURE CM_SRRO_SELL
-- NOTE   : Вывод чека на ПРРО Checkbox Kassa без печати
-- RELEASE: 03.01.2025 star 
-- RELEASE: 21.05.2025 star - обработка повторного вывода чека
--                          - фиксация времени завершения
-- RELEASE: 05.03.2026 star - обработка ранее зафискализированного чека
-- RELEASE: 15.04.2026 star - округление 50 коп
-- RELEASE: 17.04.2026 star - округление только для наличной оплаты
----------------------------------------------------------
CREATE PROCEDURE CM_SRRO_SELL
  @EKKA_ID      INT                  -- касса
, @RRO_SHIFT_ID UNIQUEIDENTIFIER     -- смена
, @RRO_CASHIER  VARCHAR(80) = ''     -- кассир
, @DOCUM_SUM    MONEY                -- сумма чека
, @DOCUM_NUMB   VARCHAR(15) = ''     -- номер документа
, @IS_MODEL     INT         = 0      -- модельный чек
, @goods        NVARCHAR(max)        -- строки чека
, @payments     NVARCHAR(max)        -- оплата
, @receipt_copy NVARCHAR(max) = NULL -- ранее отправленный чек
, @receipt_done NVARCHAR(max) = NULL -- зафискализированный чек
, @RRO_TRANSACT_ID  UNIQUEIDENTIFIER = NULL  -- код чека
, @PAY_TYPE     INT                  -- тип оплаты = 0-нал, 1-карточка, 2-чек
, @FISCAL_CODE  VARCHAR(80)  OUTPUT  -- фискальный код чека
, @MESSAGE      VARCHAR(800) OUTPUT
AS
BEGIN
SET NOCOUNT ON;
DECLARE
  @fiscal_date   DATETIME
, @fiscal_online INT     
, @document      NVARCHAR(max)
, @status        INT
, @errMessage    NVARCHAR(max)
, @answer        NVARCHAR(max)
, @receipt_dt    DATETIME
, @response_dt   DATETIME
, @result        INT = 0

-- проверка на повторный вызов
IF (@receipt_copy IS NULL) AND (@receipt_done IS NULL)
BEGIN
  -- ..заголовок
  SET @RRO_TRANSACT_ID = NEWID();  
  SELECT @document = 
  '{ "id": "'+ CAST(@RRO_TRANSACT_ID AS VARCHAR(40)) +'", 
    "custom_id": "'+ CAST(@RRO_TRANSACT_ID AS VARCHAR(40)) +'", 
    "goods": [ '+ @goods +' ],
    "payments": ['+ @payments +' ],
    "print": false'+  
    CASE WHEN @PAY_TYPE =0
           THEN ', "rounding_mode": "ROUND_50"' 
           ELSE '' END
    +' }';
END
ELSE
BEGIN
  SET @document = @receipt_copy;

  IF (@receipt_done IS NOT NULL)
    SET @answer = @receipt_done;
END

BEGIN TRY
  -- если чек уже отправлялся и зафискализирован
  IF(@answer IS NOT NULL)
  BEGIN
    SET @receipt_dt = GETDATE();
    SET @response_dt = @receipt_dt;
    SET @status = 200;

    GOTO answer_parsing;
  END

  SELECT @status = 0
      , @answer = ''
      , @errMessage = ''
      , @receipt_dt = GETDATE();

  EXEC @result = CM_SRRO_API_POST
       @EKKA_ID    = @EKKA_ID
      ,@taskUri    = 'receipt/sell'
      ,@document   = @document
      ,@status     = @status     OUTPUT
      ,@answer     = @answer     OUTPUT
      ,@errMessage = @errMessage OUTPUT;

  SET @response_dt = GETDATE();

  IF (@result <> 0 OR @status <> 200)
  BEGIN
    SET @MESSAGE = 'Ошибка продажи на РРО';
    EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                             @errMessage, 'message', @MESSAGE OUTPUT;
    SET @result =1;
    RAISERROR( @MESSAGE, 16, 1);
  END

answer_parsing:
  -- парсинг ответа

  if Object_ID('tempdb..#json_buffer') is not null
    drop table #json_buffer;
  SELECT * INTO #json_buffer
    FROM dbo.parseJSON( @answer );
  
  SELECT @fiscal_code = ''
       , @fiscal_date = GETDATE()
       , @fiscal_online = 0;
  
  SELECT @fiscal_code = StringValue
    FROM #json_buffer
    WHERE parent_ID IN (
              SELECT [Object_ID] FROM #json_buffer
                WHERE parent_ID IS NULL)
      AND [NAME] = 'fiscal_code';
  
  SELECT @fiscal_date = CAST(LEFT( StringValue, 19) AS DATETIME )
    FROM #json_buffer
    WHERE parent_ID IN (
              SELECT [Object_ID] FROM #json_buffer
                WHERE parent_ID IS NULL)
      AND [NAME] = 'fiscal_date';

  SELECT @fiscal_online = CASE WHEN StringValue ='true' THEN 1 ELSE 0 END
    FROM #json_buffer
    WHERE parent_ID IN (
              SELECT [Object_ID] FROM #json_buffer
                WHERE parent_ID IS NULL)
      AND [NAME] = 'is_online';

  -- Пишем результат
  -- ..лог
  INSERT INTO CM_SRRO_TRANSACT 
           ( RRO_TRANSACT_ID, RRO_SHIFT_ID, RRO_CASHIER, TOTAL_SUM, IS_MODEL,
             FISCAL_CODE, FISCAL_DATE, FISCAL_ONLINE, DOCUM_NUMB, 
             REQUEST_DT, REQUEST_JSON, RESPONSE_STATUS, RESPONSE_JSON, RESPONSE_DT )
    VALUES ( @RRO_TRANSACT_ID, @RRO_SHIFT_ID, @RRO_CASHIER, @DOCUM_SUM, @IS_MODEL,
             @fiscal_code, @fiscal_date, @fiscal_online, @DOCUM_NUMB, 
             @receipt_dt,  @document, @status, @answer, @response_dt  );
END TRY
BEGIN CATCH
  set @result = 3
  SET @MESSAGE = ERROR_MESSAGE()

  INSERT INTO CM_SRRO_TRANSACT 
           ( RRO_TRANSACT_ID, RRO_SHIFT_ID, RRO_CASHIER, TOTAL_SUM, DOCUM_NUMB, 
             REQUEST_DT, REQUEST_JSON, RESPONSE_STATUS, RESPONSE_JSON,
             RESPONSE_DT, ERR_MESSAGE )
    VALUES ( @RRO_TRANSACT_ID, @RRO_SHIFT_ID, @RRO_CASHIER, @DOCUM_SUM, @DOCUM_NUMB, 
             @receipt_dt, @document, @status, @answer, 
             @response_dt, @MESSAGE );
END CATCH

RETURN @result;
----------------------------------------------------------
END;
GO

GRANT EXECUTE ON CM_SRRO_SELL TO role_TWapp;
GO
