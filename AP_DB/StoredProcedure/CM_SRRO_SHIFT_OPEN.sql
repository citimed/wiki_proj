IF OBJECT_ID('CM_SRRO_SHIFT_OPEN', 'P') IS NOT NULL
    DROP PROCEDURE CM_SRRO_SHIFT_OPEN;
GO

--------------------------------------------------------
-- NAME   : PROCEDURE CM_SRRO_SHIFT_OPEN
-- NOTE   : Открытие смены РРО и внесение наличных
-- RELEASE: 04.11.2024 star 
-- RELEASE: 22.11.2024 star - сумма внесения из настроек,
--                          - Х-отчет после внесения
-- RELEASE: 10.12.2024 star - без внесения
-- RELEASE: 03.01.2024 star - начальный остаток в кассе
-- RELEASE: 10.02.2025 star - fix taxes code
-- RELEASE: 03.03.2025 star - доработки для учета Checkbox Web
--                          - блокировка Х-отчета
-- RELEASE: 24.04.2025 star - доп. проверка на факт открытия смены
-- RELEASE: 07.06.2025 star - расширенная обработка состояния смены на РРО
-- RELEASE: 20.02.2026 star - загрузка ндс вынесена в CM_SRRO_SHIFT_TAX
----------------------------------------------------------
CREATE PROCEDURE CM_SRRO_SHIFT_OPEN
  @POS_ID   INT, 
  @SHIFT_ID INT,
  @MESSAGE  VARCHAR(800) OUTPUT
AS
BEGIN
SET NOCOUNT ON;
DECLARE      
   @EKKA_ID      INT
  ,@RRO_FISCAL   VARCHAR(40)
  ,@RRO_EDRPOU   VARCHAR(20)
  ,@CASHIER_OPEN VARCHAR(80)
  ,@status       INT
  ,@answer       NVARCHAR(max)
  ,@errMessage   NVARCHAR(max)
  ,@RRO_name     VARCHAR(10)
  ,@result       INT = 0
  ,@RRO_SHIFT_ID UNIQUEIDENTIFIER
  ,@balance_coin INT = 0
  ,@STATUS_STR   VARCHAR(20);

SET @MESSAGE = '';

SET @EKKA_ID = 0
-- .. настройки для ПРРО 
SELECT TOP 1 @EKKA_ID = e.EKKA_ID
           , @RRO_FISCAL = e.EKKA_NUMB
  FROM EKKA e
  WHERE e.TR_CASH_ID = @POS_ID
    AND e.EKKA_NAME LIKE 'LTD%';

IF ISNULL(@EKKA_ID, 0) = 0
  RETURN 0;

-- данные по кассе
SELECT @status  = 0
      ,@answer  = ''
      ,@errMessage = ''

exec @result = CM_SRRO_API_GET
    @EKKA_ID    = @EKKA_ID,
    @taskUri    = 'kasa/info' ,
    @status     = @status     OUTPUT,
    @document   = @answer     OUTPUT,
    @errMessage = @errMessage OUTPUT;

IF (@result <> 0 OR @status <> 200)
BEGIN
  SET @MESSAGE = 'Ошибка получения информации по кассе';
  EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                           @errMessage, 'message', @MESSAGE OUTPUT;
  RETURN 1;
END

-- .. кассир
SET @CASHIER_OPEN = dbo.GetJsonValue( dbo.GetJsonValue( @answer, 
                          'cashier' ), 'full_name');
-- .. ЕДРПОУ предприятия
SET @RRO_EDRPOU = dbo.GetJsonValue( dbo.GetJsonValue( @answer, 
                          'organization' ), 'edrpou');

-- доп. проверка на факт раннего открытия смены
SELECT @status  = 0
      ,@answer  = ''
      ,@errMessage = ''
      ,@balance_coin = 0;

exec @result = CM_SRRO_API_GET
    @EKKA_ID    = @EKKA_ID,
    @taskUri    = 'shift',
    @status     = @status     OUTPUT,
    @document   = @answer     OUTPUT,
    @errMessage = @errMessage OUTPUT;

IF NOT (@result = 0 AND @status = 400)
BEGIN
  IF (@result <> 0 OR @status <> 200)
  BEGIN
    SET @MESSAGE = 'Ошибка проверки открытия смены';
    EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                             @errMessage, 'message', @MESSAGE OUTPUT;
    RETURN 2;
  END
  ELSE
  BEGIN
    DECLARE
      @OPENED_DT    DATETIME
    , @OLD_SHIFT_ID INT;

    -- Смена РРО уже открыта - проверяем статус и дату
    EXEC @result = CM_SRRO_SHIFT_INFO
            @json         = @answer
          , @RRO_SHIFT_ID = @RRO_SHIFT_ID OUTPUT
          , @STATUS       = @STATUS_STR   OUTPUT
          , @OPENED_DT    = @OPENED_DT    OUTPUT
          , @MESSAGE      = @MESSAGE      OUTPUT
    
    IF (@result <> 0)
      RETURN 3;
    IF (@STATUS_STR <> 'OPENED')
    BEGIN
      SET @MESSAGE = 'Ошибка статуса смены : ' + @STATUS_STR;
      RETURN 4;
    END

    IF (CAST(@OPENED_DT AS DATE) <> CAST(GETDATE() AS DATE))
    BEGIN
      -- закрываем вчерашнюю смену
      SELECT @OLD_SHIFT_ID = SHIFT_ID
        FROM CM_SRRO_SHIFT 
        WHERE RRO_SHIFT_ID = @RRO_SHIFT_ID;

      EXEC @result = CM_SRRO_SHIFT_CLOSE
              @POS_ID       = @POS_ID, 
              @SHIFT_ID     = @OLD_SHIFT_ID,
              @RRO_SHIFT_ID = @RRO_SHIFT_ID,
              @MESSAGE      = @MESSAGE OUTPUT;
      IF (@result <> 0)
        RETURN 5;
    END
    ELSE
    BEGIN
      -- смена открыта сегодня, просто возвращаем ид-р смены
      SET @RRO_SHIFT_ID = ISNULL(@RRO_SHIFT_ID, NEWID());
      GOTO save_shift;
    END
  END
END

-- открытие смены
SELECT @status  = 0
      ,@answer  = ''
      ,@errMessage = '';

EXEC @result = CM_SRRO_API_POST
      @EKKA_ID    = @EKKA_ID
    ,@taskUri    = 'shift/open'
    ,@document   = ''
    ,@status     = @status     OUTPUT
    ,@answer     = @answer     OUTPUT
    ,@errMessage = @errMessage OUTPUT;

IF (@result <> 0 OR @status <> 200)
BEGIN
  SET @MESSAGE = 'Ошибка открытия смены';
  EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                           @errMessage, 'message', @MESSAGE OUTPUT;
  RETURN 6;
END

-- доп. проверка на факт открытия смены
SELECT @status  = 0
      ,@answer  = ''
      ,@errMessage = ''
      ,@balance_coin = 0;

exec @result = CM_SRRO_API_GET
    @EKKA_ID    = @EKKA_ID,
    @taskUri    = 'shift',
    @status     = @status     OUTPUT,
    @document   = @answer     OUTPUT,
    @errMessage = @errMessage OUTPUT;

IF (@result <> 0 OR @status <> 200)
BEGIN
  SET @MESSAGE = 'Ошибка открытия смены';
  EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                           @errMessage, 'message', @MESSAGE OUTPUT;
  RETURN 7;
END

-- SET @RRO_SHIFT_ID = NEWID();  
-- проверяем статус и получим Ид-р смены РРО
EXEC @result = CM_SRRO_SHIFT_INFO
        @json         = @answer
      , @RRO_SHIFT_ID = @RRO_SHIFT_ID OUTPUT 
      , @STATUS       = @STATUS_STR   OUTPUT
      , @MESSAGE      = @MESSAGE      OUTPUT

IF (@result <> 0)
  RETURN 3;
IF (@STATUS_STR <> 'OPENED')
BEGIN
  SET @MESSAGE = 'Ошибка статуса смены : ' + @STATUS_STR;
  RETURN 4;
END

save_shift:
-- регистрация смены РРО в Трейде
INSERT INTO CM_SRRO_SHIFT 
    (RRO_SHIFT_ID, SHIFT_ID, RRO_FISCAL, RRO_EDRPOU, CASHIER_OPEN, SHIFT_DT_OPEN)
  VALUES 
    (@RRO_SHIFT_ID, @SHIFT_ID, @RRO_FISCAL, @RRO_EDRPOU, @CASHIER_OPEN, GETDATE() );

-- начальный остаток в кассе и налоговые ставки
EXEC CM_SRRO_SHIFT_TAX
       @EKKA_ID      = @EKKA_ID
      ,@RRO_SHIFT_ID = @RRO_SHIFT_ID
      ,@MESSAGE      = @MESSAGE OUTPUT;


RETURN 0;
----------------------------------------------------------
END;
GO

GRANT EXECUTE ON CM_SRRO_SHIFT_OPEN TO role_TWapp;
GO
