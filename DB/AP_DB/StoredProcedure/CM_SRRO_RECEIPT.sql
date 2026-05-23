IF OBJECT_ID('CM_SRRO_RECEIPT', 'P') IS NOT NULL
    DROP PROCEDURE CM_SRRO_RECEIPT;
GO

--------------------------------------------------------
-- NAME   : PROCEDURE CM_SRRO_RECEIPT
-- NOTE   : Отправка чека на локальный РРО с оплатой на терминале, 
--          только Checkbox Kassa, без печати
-- RELEASE: 05.01.2025 star
-- RELEASE: 27.01.2025 star - наименования для бонусов
-- RELEASE: 06.02.2025 star - управление печатью
-- RELEASE: 10.02.2025 star - формирование модельного чека МС
-- RELEASE: 01.03.2025 star - доработки для режима PRINT
-- RELEASE: 19.03.2025 star - для наличных округление до 10 коп вверх
-- RELEASE: 27.03.2025 star - доработка оплаты по карте
-- RELEASE: 28.03.2025 star - учет округления суммы чека
-- RELEASE: 31.03.2025 star - hot fix
--                          - свертывание по артикулу
-- RELEASE: 02.04.2025 star - если не описан РРО, то просто прописываем оплату 
-- RELEASE: 05.04.2025 star - доработки компенсации округления
-- RELEASE: 24.04.2025 star - доп. проверка на пустую скидку
-- RELEASE: 21.05.2025 star - повышение точности для операций BIGINT
-- RELEASE: 21.05.2025 star - обработка повторного вывода чека
-- RELEASE: 29.05.2025 star - исключение получение кассира
-- RELEASE: 29.05.2025 star - logging, lock
-- RELEASE: 04.06.2025 star - автооткрытие смены при необходимости
-- RELEASE: 07.06.2025 star - проверка и корректировка смены РРО
-- RELEASE: 10.06.2025 star - доработка проверки на повторный вывод чека
-- RELEASE: 11.06.2025 star - обработка чека из строй смены
-- RELEASE: 12.06.2025 star - блокировка оплаты менее суммы чека
-- RELEASE: 20.02.2026 star - контроль и логирование ошибок НДС
-- RELEASE: 20.02.2026 star - проверка и загрузка ндс 
-- RELEASE: 05.03.2026 star - проверка на уже зафискализированный чек
-- RELEASE: 08.04.2026 star - формирование идентификатора оплаты для терминала
-- RELEASE: 17.04.2026 star - передача типа оплаты в чек
----------------------------------------------------------
CREATE PROCEDURE CM_SRRO_RECEIPT 
  @DOCUM_ID    INT        -- код документа
, @PAY_TYPE    INT        -- тип оплаты = 0-нал, 1-карточка, 2-чек
, @RECEIVED    MONEY = 0  -- Полученная сумма
, @PRINT       INT   = 0  -- =1 для печати на принтер
, @FISCAL_CODE VARCHAR(80)  OUTPUT  -- фискальный код чека
, @MESSAGE     VARCHAR(800) OUTPUT  -- ошибки
AS
BEGIN
SET NOCOUNT ON;
DECLARE
  @result        INT = 0
 ,@RRO_SHIFT_ID  UNIQUEIDENTIFIER 
 ,@REGISTR_STATE INT
 ,@POS_ID        INT
 ,@EKKA_ID       INT
 ,@SHIFT_ID      INT 
 ,@DOCUM_SUM     MONEY
 ,@DOCUM_NUMB    VARCHAR(15)
 ,@DOCUM_DATE    DATE
 ,@status        INT
 ,@goods         NVARCHAR(max)
 ,@answer        NVARCHAR(max)
 ,@errMessage    NVARCHAR(max)
 ,@IS_MODEL      INT = 0
 ,@RRO_FISCAL    VARCHAR(40)
 ,@RRO_CASHIER   VARCHAR(80) = ''
 ,@PLU_BONUS     VARCHAR(15) = '999999'
 ,@round_plu     VARCHAR(15) = '999996'  --  ОКРУГЛЕНИЕ
 ,@payments      NVARCHAR(max)
 ,@bonus_sum     BIGINT = 0
 ,@wb_total      BIGINT = 0
 ,@ms_total      MONEY = 0
 ,@doc_sum       MONEY
 ,@dif_sum       MONEY
 ,@dt            DATETIME
 ,@receipt_copy  NVARCHAR(max)
 ,@log_dt        DATETIME
, @taskUri       NVARCHAR(max)
, @receipt_done     NVARCHAR(max)    -- зафискализированный чек
, @RRO_TRANSACT_ID  UNIQUEIDENTIFIER -- код чека
, @PURCHASE_ID      UNIQUEIDENTIFIER -- код оплаты на терминале
; 

SET @MESSAGE = '';

SELECT @POS_ID        = t.TR_CASH_ID 
     , @SHIFT_ID      = t.SHIFT_ID
     , @DOCUM_SUM     = t.DOCUM_SUMM_HOME
     , @DOCUM_NUMB    = t.DOCUM_NUMB
     , @REGISTR_STATE = ISNULL(t.TRANSACT_REGISTR_STATE, 0)
     , @dt = DATEADD( MINUTE, -5, t.DOCUM_DATE)
     , @DOCUM_DATE    = t.DOCUM_DATE
     , @PURCHASE_ID   = t.PURCHASE_ID
  FROM TRANSACT t
  WHERE t.DOCUM_ID = @DOCUM_ID;

IF ((ROUND(@RECEIVED, 1) - ROUND(@DOCUM_SUM, 1)) < 0)    
BEGIN
  -- если сумма оплаты меньше суммы чека с учетом бонусов, то не отправляем чек
  SET @MESSAGE = 'Сумма оплаты меньше суммы чека. Повторите оплату с контролем суммы';  
  RETURN 1;
END

IF (@DOCUM_DATE <> CAST(GETDATE() AS DATE))
BEGIN
  -- чек из старой смены, берем текущую
  SET @SHIFT_ID = NULL;
  SELECT TOP 1 @SHIFT_ID = s.SHIFT_ID
    FROM [SHIFT] s
    WHERE s.TR_CASH_ID = @POS_ID
      AND s.SHIFT_DT_CLOSE IS NULL
      AND CAST(s.SHIFT_DT_OPEN AS DATE) = CAST(GETDATE() AS DATE);   

  IF (@SHIFT_ID IS NULL)
  BEGIN
    SET @MESSAGE = 'Нет открытой смены на этой кассе';
    RETURN 1;
  END
END

-- фиск касса 
SELECT TOP 1 @EKKA_ID    = e.EKKA_ID
           , @RRO_FISCAL = e.EKKA_NUMB
  FROM EKKA e
  WHERE e.TR_CASH_ID = @POS_ID
    AND e.EKKA_NAME LIKE 'LTD%';

-- если не описан РРО, то просто прописываем оплату  
-- наличный или с отметкой РРО не выводим, если это не печать
IF (ISNULL(@EKKA_ID, 0) = 0) OR 
   ( (@PRINT = 0) AND
     ((@PAY_TYPE = 0) OR (@REGISTR_STATE > 0) OR (@DOCUM_SUM =0))
   )
BEGIN
  IF (@REGISTR_STATE > 0) OR (@DOCUM_SUM =0)
    RETURN 0;
  -- признак оплаты
  UPDATE TRANSACT SET 
        TRANSACT_IS_PAYD = 1
      , TRANSACT_PAYTYPE = @PAY_TYPE
      , RECEIVED_SUM     = @RECEIVED
    WHERE DOCUM_ID = @DOCUM_ID;
  RETURN 0;  
END

EXEC @result = CM_SRRO_SHIFT_CHECK
          @POS_ID       = @POS_ID, 
          @SHIFT_ID     = @SHIFT_ID,
          @RRO_SHIFT_ID = @RRO_SHIFT_ID OUTPUT,
          @MESSAGE      = @MESSAGE      OUTPUT;
IF (@result <> 0)
  RETURN 1;

IF EXISTS( SELECT 1 FROM LINE_TRANSACTION l
       INNER JOIN PLU p ON p.PLU_ID = l.LINE_PLU_ID
                       AND p.DEPARTMENT_ID = 67  -- MS
       WHERE l.DOCUM_ID = @DOCUM_ID )
BEGIN
  SELECT @ms_total = SUM(l.LINE_QUAN * l.LINE_PRICEFULL_HOME)
  FROM LINE_TRANSACTION l
       INNER JOIN PLU p ON p.PLU_ID = l.LINE_PLU_ID
                       AND p.DEPARTMENT_ID = 67  -- MS
       WHERE l.DOCUM_ID = @DOCUM_ID;
END

-- состав чека
DECLARE @doc_lines TABLE
( LINE_ID   INT
, PLU_ID    VARCHAR(15)
, QUAN      MONEY
, PRICE     MONEY
)

IF (@ms_total > 0)
BEGIN
  SET @IS_MODEL = 1;
  INSERT INTO @doc_lines (LINE_ID, PLU_ID, QUAN, PRICE)
  SELECT LINE_ID, PLU_ID, QUAN, PRICE
    FROM dbo.CM_SRRO_RECEIPT_MS( @ms_total, @dt )
  ----------------
  UNION ALL
  ----------------
  -- факт МП+
  SELECT l.LINE_ID, l.LINE_PLU_ID, l.LINE_QUAN, l.LINE_PRICEFULL_HOME    
    FROM LINE_TRANSACTION l                                    
      INNER JOIN PLU p ON p.PLU_ID = l.LINE_PLU_ID
                      AND p.DEPARTMENT_ID <> 67  -- not MS
                      AND p.PLU_ID NOT IN (@PLU_BONUS, @round_plu)
    WHERE l.DOCUM_ID = @DOCUM_ID;
END
ELSE
BEGIN
  INSERT INTO @doc_lines (LINE_ID, PLU_ID, QUAN, PRICE)
  SELECT l.LINE_ID, l.LINE_PLU_ID, l.LINE_QUAN, l.LINE_PRICEFULL_HOME    
    FROM LINE_TRANSACTION l                                    
    WHERE l.DOCUM_ID = @DOCUM_ID
      AND l.LINE_PLU_ID NOT IN (@PLU_BONUS, @round_plu);
END

-- проверка на повторный вызов
SELECT @receipt_copy    = REQUEST_JSON 
     , @RRO_TRANSACT_ID = RRO_TRANSACT_ID
  FROM CM_SRRO_TRANSACT
  WHERE DOCUM_NUMB = @DOCUM_NUMB
    AND RRO_SHIFT_ID = @RRO_SHIFT_ID
    AND FISCAL_CODE IS NULL
    AND (RESPONSE_STATUS <> 200 OR ISNULL(ERR_MESSAGE,'') <> '')
    AND RESPONSE_STATUS <> 422
  ORDER BY REQUEST_DT DESC

IF (@receipt_copy IS NOT NULL)
BEGIN
  -- ..чек уже отправлялся
  -- проверка на уже зафискализированный чек
  SELECT @status  = 0
        ,@answer  = ''
        ,@errMessage = '';

  SET @taskUri = REPLACE('receipts/{id}', '{id}', 
                         CAST(@RRO_TRANSACT_ID AS VARCHAR(40)));  
  
  EXEC @result = CM_SRRO_API_GET
      @EKKA_ID    = @EKKA_ID,
      @taskUri    = @taskUri,
      @status     = @status     OUTPUT,
      @document   = @answer     OUTPUT,
      @errMessage = @errMessage OUTPUT;

  IF (@result = 0 AND @status = 200)
  BEGIN
    SET @receipt_done = @answer;
  END

  GOTO sell;
END  

-- проверка ндс
IF NOT EXISTS( SELECT 1 FROM CM_SRRO_TAXES 
                WHERE RRO_SHIFT_ID = @RRO_SHIFT_ID )
BEGIN
  EXEC @result = CM_SRRO_SHIFT_TAX
        @EKKA_ID      = @EKKA_ID
       ,@RRO_SHIFT_ID = @RRO_SHIFT_ID
       ,@MESSAGE      = @MESSAGE OUTPUT;
END

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

IF EXISTS(SELECT 1 FROM @doc_lines l
      INNER JOIN PLU p ON p.PLU_ID = l.PLU_ID
      LEFT JOIN CM_SRRO_TAXES x ON x.RRO_SHIFT_ID = @RRO_SHIFT_ID
                               AND x.TAXES_RATE = p.PLU_TAX
                               AND p.PLU_TAX IN (7,20)
    WHERE l.PLU_ID IS NOT NULL
      AND x.TAXES_ID IS NULL
    )
BEGIN
  SET @MESSAGE = '';
  -- есть товары, по которым не определены налоги, логируем
  IF NOT EXISTS(SELECT 1 FROM CM_SRRO_TAXES WHERE RRO_SHIFT_ID = @RRO_SHIFT_ID)
  BEGIN
    SET @MESSAGE = 'Не определены налоги';
  END
  ELSE
  BEGIN
    SELECT TOP 1 @MESSAGE = 'Ошибочный НДС: '+ ISNULL( CAST(p.PLU_TAX AS VARCHAR(10)),'пусто')
                          + ' у артикула: '+ RTRIM(l.PLU_ID)
      FROM @doc_lines l
        INNER JOIN PLU p ON p.PLU_ID = l.PLU_ID
                        AND p.PLU_TAX NOT IN (7,20)
    WHERE l.PLU_ID IS NOT NULL
  END

  SET @MESSAGE += ' для ПРРО: ' + CAST(@POS_ID AS VARCHAR(10))
                + ', смена: ' + CAST(@SHIFT_ID AS VARCHAR(10))
                + ', чек: ' + RTRIM(@DOCUM_NUMB);

  EXEC CM_SRRO_SAVELOG  @MESSAGE;
  SET @MESSAGE = '';
END

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
       , taxes    = COALESCE( x.TAXES_ID,
                              CASE p.PLU_TAX WHEN 7 THEN 1 
                                             WHEN 20 THEN 2
                                             ELSE NULL END,
                              CASE WHEN p.DEPARTMENT_ID IN (67, 63)
                                             THEN 1  -- MS & MP
                                             ELSE 2 END
                            )
       , l.LINE_ID
    FROM @doc_lines l                                    
      INNER JOIN PLU p ON p.PLU_ID = l.PLU_ID
      LEFT JOIN CM_SRRO_TAXES x ON x.RRO_SHIFT_ID = @RRO_SHIFT_ID
                               AND x.TAXES_RATE = p.PLU_TAX 
                               AND p.PLU_TAX IN (7,20)
    WHERE l.PLU_ID IS NOT NULL
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

SET @goods = '';

;WITH total
AS (
  SELECT code, [name], taxes
      , price = CAST( CAST(SUM(price * quantity) as money) / SUM(quantity) AS BIGINT)
      , quantity = SUM(quantity) 
      , bonus = SUM(bonus)
    FROM @lines
    GROUP BY code, [name], taxes
)
SELECT @goods = @goods
                 + CASE WHEN @goods = '' THEN '' ELSE ',' END
                 + dbo.CM_SRRO_LINE( code,  [name], price, quantity, 
                                     taxes, bonus )   
  FROM total  
  ORDER BY [name];

SET @payments = '';
-- платежный терминал
IF (@PAY_TYPE = 1)
BEGIN
  IF(@PURCHASE_ID IS NULL)
  BEGIN
    SET @PURCHASE_ID = NEWID();

    UPDATE TRANSACT SET PURCHASE_ID = @PURCHASE_ID
      WHERE DOCUM_ID = @DOCUM_ID;
  END

  EXEC @result = CM_SPAY_PURCHASE
          @POS_ID      = @POS_ID,
          @DOCUM_NUMB  = @DOCUM_NUMB,
          @DOCUM_SUM   = @RECEIVED,
          @PURCHASE_ID = @PURCHASE_ID,
          @PAYMENTS    = @payments OUTPUT,
          @MESSAGE     = @MESSAGE  OUTPUT;

  IF(@result <> 0)
    RETURN 2;  -- ошибка платежного терминала
END
ELSE
BEGIN
  -- оплата наличными
  SET @RECEIVED = CEILING(@RECEIVED * 10) /10;
END
-- секция оплаты
SET @payments = dbo.CM_SRRO_PAYMENT( CAST(@RECEIVED * 100 AS INT), @payments, @PAY_TYPE );

sell:
-- чек на РРО без печати или только регистрация фискализации

EXEC @result = CM_SRRO_SELL
        @EKKA_ID      = @EKKA_ID
      , @RRO_SHIFT_ID = @RRO_SHIFT_ID
      , @RRO_CASHIER  = @RRO_CASHIER
      , @DOCUM_SUM    = @DOCUM_SUM
      , @DOCUM_NUMB   = @DOCUM_NUMB
      , @IS_MODEL     = @IS_MODEL
      , @goods        = @goods
      , @payments     = @payments
      , @receipt_copy = @receipt_copy
      , @receipt_done = @receipt_done
      , @RRO_TRANSACT_ID = @RRO_TRANSACT_ID
      , @PAY_TYPE     = @PAY_TYPE
      , @FISCAL_CODE  = @FISCAL_CODE OUTPUT
      , @MESSAGE      = @MESSAGE     OUTPUT;

IF (@result <> 0)
  RETURN @result;

  -- ..признак в строки 
  UPDATE l SET LINETRANS_IS_REGISTR =1
    FROM @doc_lines t
      INNER JOIN LINE_TRANSACTION l ON t.LINE_ID = l.LINE_ID;
  -- ..признак в документ
  UPDATE TRANSACT SET 
      TRANSACT_REGISTR_STATE = 2
    , TRANSACT_IS_PAYD = 1
    , TRANSACT_PAYTYPE = @PAY_TYPE
    , RECEIVED_SUM     = @RECEIVED
    WHERE DOCUM_ID = @DOCUM_ID;

RETURN @result;
----------------------------------------------------------
END
GO

GRANT EXECUTE ON CM_SRRO_RECEIPT TO role_TWapp;
GO
