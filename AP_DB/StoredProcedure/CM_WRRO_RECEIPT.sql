IF OBJECT_ID('CM_WRRO_RECEIPT', 'P') IS NOT NULL
    DROP PROCEDURE CM_WRRO_RECEIPT;
GO

--------------------------------------------------------
-- NAME   : PROCEDURE CM_WRRO_RECEIPT
-- NOTE   : Отправка чека на облачный РРО с открытием смены
-- RELEASE: 02.03.2025 star
-- RELEASE: 06.03.2025 star - уточнение данных чека для сохранения
-- RELEASE: 26.03.2025 star - доработка оплаты по карте
-- RELEASE: 28.03.2025 star - учет округления суммы чека
-- RELEASE: 30.03.2025 star - параметр учета округления суммы чека
-- RELEASE: 04.04.2025 star - ндс по правилам 
-- RELEASE: 05.04.2025 star - доработки компенсации округления
-- RELEASE: 07.04.2025 star - замена спец символов в наименовании товара
-- RELEASE: 24.04.2025 star - повышение точности для операций BIGINT
-- RELEASE: 08.04.2026 star - формирование идентификатора оплаты для терминала
-- RELEASE: 29.04.2026 star - данные по карте из ответа по чеку
----------------------------------------------------------
CREATE PROCEDURE CM_WRRO_RECEIPT 
  @DOCUM_ID    INT      -- код документа
, @PAY_TYPE    INT      -- тип оплаты = 0-нал, 1-карточка, 2-чек
, @RECEIVED    MONEY    -- Полученная сумма
, @FISCAL_CODE VARCHAR(80)  OUTPUT  -- фискальный код чека
, @MESSAGE     VARCHAR(800) OUTPUT  -- ошибки
AS
BEGIN
SET NOCOUNT ON;
DECLARE
  @result        INT = 0
 ,@POS_ID        INT
 ,@DOCUM_SUM     MONEY
 ,@DOCUM_NUMB    VARCHAR(15)
 ,@settings      VARCHAR(800)
 ,@status        INT
 ,@taskUri       NVARCHAR(MAX)
 ,@headers       NVARCHAR(MAX)
 ,@document      NVARCHAR(max)
 ,@line          NVARCHAR(max)
 ,@answer        NVARCHAR(max)
 ,@errMessage    NVARCHAR(max)
 ,@status_str    VARCHAR(200)
 ,@TOKEN         VARCHAR(800)
 ,@RRO_SHIFT_ID    UNIQUEIDENTIFIER
 ,@RRO_TRANSACT_ID UNIQUEIDENTIFIER
 ,@RRO_CASHIER   VARCHAR(80) = ''
 ,@PLU_BONUS     VARCHAR(15) = '999999'
 ,@round_plu     VARCHAR(15) = '999996'  --  ОКРУГЛЕНИЕ
 ,@payments      NVARCHAR(max)
 ,@pay_sum       VARCHAR(20)
 ,@receipt_dt    DATETIME
 ,@bonus_sum     BIGINT = 0
 ,@wb_total      BIGINT = 0
 ,@ms_total      BIGINT = 0
 ,@doc_sum       MONEY
 ,@dif_sum       MONEY
 ,@step_max      INT = 10     -- число проверок статуса чека
 ,@timeout       INT = 1      -- таймаут запроса статуса, сек
 ,@sell_status   VARCHAR(20)
 ,@root          INT
 ,@StringValue   VARCHAR(2000)
 ,@PURCHASE_ID   UNIQUEIDENTIFIER -- код оплаты на терминале
;  
  
SET @MESSAGE = '';

SELECT @POS_ID      = t.TR_CASH_ID 
     , @DOCUM_SUM   = t.DOCUM_SUMM_HOME
     , @DOCUM_NUMB  = t.DOCUM_NUMB
     , @PURCHASE_ID = t.PURCHASE_ID
  FROM TRANSACT t
  WHERE t.DOCUM_ID = @DOCUM_ID;
-------------------------------------------
-- SET @MESSAGE = 'Ошибка РРО';
-- RETURN 1;
----------------------------------------------------

-- получение смены (если нет, то открыть)
EXEC @result = CM_WRRO_SHIFT_OPEN 
        @MESSAGE = @MESSAGE  OUTPUT

IF (@result <> 0)
  RETURN 1;

SELECT TOP 1 @TOKEN = TOKEN
           , @RRO_CASHIER = CASHIER_LOGIN
           , @RRO_SHIFT_ID = RRO_SHIFT_ID
  FROM CM_WRRO;

-- ..настройки для облачного Checkbox
SELECT @settings = CONST_VALUE
  FROM CONSTANTS
  WHERE CONST_ID = 'CM_WRRO_SETTINGS';

-- чек 
DECLARE @doc_lines TABLE
( LINE_ID   INT
, PLU_ID    VARCHAR(15)
, QUAN      MONEY
, PRICE     MONEY
)

INSERT INTO @doc_lines (LINE_ID, PLU_ID, QUAN, PRICE)
SELECT l.LINE_ID, l.LINE_PLU_ID, l.LINE_QUAN, l.LINE_PRICEFULL_HOME    
  FROM LINE_TRANSACTION l                                    
  WHERE l.DOCUM_ID = @DOCUM_ID
    AND l.LINE_PLU_ID NOT IN (@PLU_BONUS, @round_plu);

-- ..сбор строк
DECLARE @lines TABLE
( code     varchar(15)
, [name]   varchar(250)
, price    BIGINT
, quantity BIGINT
, taxes    INT
, numb     INT
, bonus    BIGINT
);

;WITH lines
AS (
  SELECT code = RTRIM(l.PLU_ID)
       , [name] = REPLACE( RTRIM(
                     CASE WHEN len(isnull(p.PLU_NOTE,'')) > 3         
                            THEN left(p.PLU_NOTE, len(p.PLU_NOTE) - cast(isnull(SERV_MANHOUR,0) as int) )
                            ELSE left(p.PLU_NAME, len(p.PLU_NAME) - isnull(SERV_MANPOWER,0) ) END )
                   ,'"','')
       , price    = CAST(l.PRICE * 100 AS BIGINT)
       , quantity = CAST(l.QUAN * 1000 AS BIGINT)
       , taxes    = x.TAXES_ID
       , l.LINE_ID
    FROM @doc_lines l 
      INNER JOIN PLU p ON p.PLU_ID = l.PLU_ID
      LEFT JOIN CM_SRRO_TAXES x ON x.RRO_SHIFT_ID = @RRO_SHIFT_ID
                               AND x.TAXES_RATE = CASE ISNULL(p.PLU_TAX,0) WHEN 0 THEN 7.0 ELSE p.PLU_TAX END 
)
INSERT INTO @lines
SELECT code, [name], price, quantity, taxes, LINE_ID, 0
  FROM lines;

SELECT @bonus_sum = ISNULL(l.LINE_QUAN * l.LINE_PRICEFULL_HOME * 100 ,0)
  FROM LINE_TRANSACTION l
  WHERE l.DOCUM_ID = @DOCUM_ID
    AND l.LINE_PLU_ID = @PLU_BONUS;

SELECT @doc_sum = ISNULL(SUM(ROUND( price * quantity / 100000.,2)),0) 
  FROM (
    SELECT price = CAST( CAST(SUM(price * quantity) as money) / SUM(quantity) AS BIGINT)
          , quantity = SUM(quantity)
      FROM @lines
      GROUP BY code, [name], taxes
  ) t

IF (@PAY_TYPE = 1)
BEGIN
  SET @dif_sum = @RECEIVED - @doc_sum - ISNULL(@bonus_sum / 100.0, 0);
  IF (@dif_sum <> 0)
    SET @bonus_sum = ISNULL(@bonus_sum, 0) + (@dif_sum * 100); 
END

IF (ISNULL(@bonus_sum,0) <> 0)
BEGIN
  SET @wb_total = @doc_sum * 100000;

  UPDATE @lines set 
    bonus = ROUND( 1.0 * price * quantity * @bonus_sum / @wb_total ,0);

  SELECT @wb_total = sum(bonus)
    FROM @lines;

  IF (@wb_total <> @bonus_sum)
  BEGIN
    -- коррекция на округление
    UPDATE @lines SET bonus = bonus + @bonus_sum - @wb_total
      WHERE numb = (SELECT MAX( numb ) FROM @lines);                    
  END
END -- (@bonus_sum <> 0)

SET @document = '';

;WITH total
AS (
  SELECT code, [name], taxes
      , price = CAST( CAST(SUM(price * quantity) as money) / SUM(quantity) AS BIGINT)
      , quantity = SUM(quantity) 
      , bonus = SUM(bonus)
    FROM @lines
    GROUP BY code, [name], taxes
)
SELECT @document = @document
                 + CASE WHEN @document = '' THEN '' ELSE ',' END +
'{ "good": {
  "code": "'+ code +'",
  "name": "'+ dbo.CM_SRRO_NORMAL_NAME( [name] ) +'",
  "price": '+ CAST( price AS VARCHAR(20)) +',
  "tax": ['+ CAST( taxes AS VARCHAR(20)) +'] },
  "quantity": '+ CAST( quantity AS VARCHAR(20)) +
  CASE WHEN bonus = 0 THEN '' ELSE ',
   "discounts": [
   { "type": "'+ CASE WHEN bonus < 0 THEN 'DISCOUNT' ELSE 'EXTRA_CHARGE' END +'",
     "name": "'+ CASE WHEN bonus < 0 THEN 'Знижка КБ' ELSE 'Нараховано КБ' END +'",
     "mode": "VALUE",
     "value": '+ CAST( abs(bonus) AS VARCHAR(20)) +'
   }]' END +'
}'
  FROM total  
  ORDER BY [name];

-- сумма оплаты
SET @pay_sum = CAST(CAST(@RECEIVED * 100 AS BIGINT) AS VARCHAR(20));

SET @payments = '';
-- платежный терминал
IF (@PAY_TYPE = 1)
BEGIN
  SET @payments = '';
  SELECT TOP 1 @payments = ISNULL(RESPONSE_JSON, '')
    FROM CM_SRRO_TRANSACT 
    WHERE DOCUM_NUMB = @DOCUM_NUMB
      AND RESPONSE_STATUS = 200
      AND IS_MODEL = 1

  SELECT TOP 1 @payments = json_row
    FROM dbo.GetJsonArray( @payments, 'payments')

  IF (ISNULL(@payments,'') ='')
  BEGIN
    SET @MESSAGE = 'Ошибка парсинга оплаты';
    RAISERROR( @MESSAGE, 16, 1);
  END 
END -- платежный терминал
ELSE
BEGIN  -- оплата наличными
  SET @payments = '
{ "type": "CASH",
  "value": '+ @pay_sum +',
  "label": "Готівка"
}';
END

-- ..заголовок
SET @RRO_TRANSACT_ID = NEWID();
SELECT @document = 
'{ "id": "'+ CAST(@RRO_TRANSACT_ID AS VARCHAR(40)) +'", 
  "goods": [ '+ @document +' ],
  "payments": ['+ @payments +'    
  ],
  "rounding": true
}'

SELECT @status = 0
     , @answer = ''
     , @status_str = ''
     , @errMessage = ''
     , @headers    = FORMATMESSAGE('{"Authorization":"Bearer %s" }', @TOKEN )
     , @receipt_dt = GETDATE();

BEGIN TRY
  EXEC @result = CM_SQLHTTP_POST_FULL
           @settings   = @settings
          ,@taskUri    = 'receipts/sell'
          ,@headers    = @headers    OUTPUT      
          ,@document   = @document
          ,@status     = @status     OUTPUT
          ,@answer     = @answer     OUTPUT
          ,@errMessage = @errMessage OUTPUT;

  IF (@result <> 0 OR @status > 210)
  BEGIN
    SET @MESSAGE = 'Ошибка создания чека РРО';
    EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                             @errMessage, 'message', @MESSAGE OUTPUT;
    SET @result =1;
    RAISERROR( @MESSAGE, 16, 1);
  END

  WHILE (@step_max > 0)
  BEGIN
    -- задержка
    WAITFOR DELAY @timeout;
    SET @step_max -= 1;

    SELECT @status  = 0
          ,@answer  = ''
          ,@errMessage = ''
          ,@taskUri    = 'receipts/'+ CAST(@RRO_TRANSACT_ID AS VARCHAR(40))
          ,@headers    = FORMATMESSAGE('{"Authorization":"Bearer %s" }', @TOKEN )

    BEGIN TRY
      EXEC @result = CM_SQLHTTP_GET_FULL
        @settings   = @settings
      , @taskUri    = @taskUri
      , @headers    = @headers    OUTPUT
      , @document   = @answer     OUTPUT
      , @status     = @status     OUTPUT
      , @errMessage = @errMessage OUTPUT;
    END TRY
    BEGIN CATCH
      SET @result = 99
      SET @errMessage = ERROR_MESSAGE()
    END CATCH

    IF (@result <> 0 OR @status > 210)
    BEGIN
      SET @MESSAGE = 'Ошибка получения статуса чека РРО';
      EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                               @errMessage, 'message', @MESSAGE OUTPUT;
      SET @result =2;
      RAISERROR( @MESSAGE, 16, 1);
    END
    -- проверка статуса
    IF ISNULL(LEN(@answer),0) < 100
      CONTINUE;

    -- парсинг ответа
    if Object_ID('tempdb..#json_buffer') is not null
      drop table #json_buffer;
    SELECT * INTO #json_buffer
      FROM dbo.parseJSON( @answer );

    SELECT @root = [Object_ID] 
      FROM #json_buffer
      WHERE parent_ID IS NULL;

    EXEC GET_VALUE_JSON_BUFFER  @root, 'status', @sell_status OUTPUT;
    IF(@sell_status = 'DONE')
      BREAK;
  END

  IF(@sell_status <> 'DONE')
  BEGIN
    SET @MESSAGE = 'Нет подтверждения регистрации чека РРО';
    SET @result =3;
    RAISERROR( @MESSAGE, 16, 1);
  END  
  
  DECLARE
    @fiscal_date   DATETIME    = GETDATE() --> FISCAL_DATE
  , @fiscal_online INT         = 0         --> FISCAL_ONLINE
  
  EXEC GET_VALUE_JSON_BUFFER  @root, 'fiscal_code', @fiscal_code OUTPUT;
  EXEC GET_VALUE_JSON_BUFFER  @root, 'fiscal_date', @StringValue OUTPUT;
  SET @fiscal_date = CAST(LEFT( @StringValue, 19) AS DATETIME );

  EXEC GET_VALUE_JSON_BUFFER  @root, 'is_created_offline', @StringValue OUTPUT;
  SET @fiscal_online = CASE WHEN @StringValue ='false' THEN 1 ELSE 0 END;

  -- Пишем результат
  -- ..лог
  INSERT INTO CM_SRRO_TRANSACT 
           ( RRO_TRANSACT_ID, RRO_SHIFT_ID, RRO_CASHIER, TOTAL_SUM, IS_MODEL,
             FISCAL_CODE, FISCAL_DATE, FISCAL_ONLINE, DOCUM_NUMB, 
             REQUEST_DT, REQUEST_JSON, RESPONSE_STATUS, RESPONSE_JSON )
    VALUES ( @RRO_TRANSACT_ID, @RRO_SHIFT_ID, @RRO_CASHIER, @DOCUM_SUM, 0,
             @fiscal_code, @fiscal_date, @fiscal_online, @DOCUM_NUMB, 
             @receipt_dt, @document, @status, @answer  );
  -- ..признак в строки 
  UPDATE l SET LINETRANS_IS_REGISTR =1
    FROM @doc_lines t
      INNER JOIN LINE_TRANSACTION l ON t.LINE_ID = l.LINE_ID;
  -- ..признак в документ
  UPDATE TRANSACT SET 
      TRANSACT_REGISTR_STATE = 2
    , TRANSACT_IS_PAYD       = 1
    , TRANSACT_PAYTYPE       = @PAY_TYPE
    WHERE DOCUM_ID = @DOCUM_ID;

END TRY
BEGIN CATCH
  set @result = 3
  SET @MESSAGE = ERROR_MESSAGE()

  INSERT INTO CM_SRRO_TRANSACT 
           ( RRO_TRANSACT_ID, RRO_SHIFT_ID, RRO_CASHIER, TOTAL_SUM, DOCUM_NUMB, 
             REQUEST_DT, REQUEST_JSON, RESPONSE_STATUS, RESPONSE_JSON, ERR_MESSAGE )
    VALUES ( @RRO_TRANSACT_ID, @RRO_SHIFT_ID, @RRO_CASHIER, @DOCUM_SUM, @DOCUM_NUMB, 
             @receipt_dt, @document, @status, @answer, @MESSAGE );
END CATCH

RETURN @result;
----------------------------------------------------------
END
GO

GRANT EXECUTE ON CM_WRRO_RECEIPT TO role_TWapp;
GO
