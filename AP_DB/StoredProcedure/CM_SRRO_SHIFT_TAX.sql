IF OBJECT_ID('CM_SRRO_SHIFT_TAX', 'P') IS NOT NULL
    DROP PROCEDURE CM_SRRO_SHIFT_TAX;
GO

--------------------------------------------------------
-- NAME   : PROCEDURE CM_SRRO_SHIFT_TAX
-- NOTE   : Налоги и нач.остаток РРО 
-- RELEASE: 27.02.2026 star 
----------------------------------------------------------
CREATE PROCEDURE CM_SRRO_SHIFT_TAX
  @EKKA_ID      INT
, @RRO_SHIFT_ID UNIQUEIDENTIFIER
, @MESSAGE      VARCHAR(800) OUTPUT
AS
BEGIN
SET NOCOUNT ON;
DECLARE      
  @result       INT = 0
, @balance_coin INT = 0
, @status       INT
, @answer       NVARCHAR(max)
, @errMessage   NVARCHAR(max)
, @TAXES_ID     INT         
, @TAXES_RATE   MONEY       
, @TAXES_SYMBOL VARCHAR(10);

SET @MESSAGE = '';

BEGIN TRY
  -- начальный остаток в кассе
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
    SET @MESSAGE = 'Ошибка получения остатка в РРО';
    EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                             @errMessage, 'message', @MESSAGE OUTPUT;
    RAISERROR (@MESSAGE, 16, 1);
  END

  SELECT @balance_coin = dbo.GetJsonValue(  dbo.GetJsonValue( 
                                @answer, 'balance' ), 'initial');

  UPDATE CM_SRRO_SHIFT SET BALANCE_IN = @balance_coin / 100.0
    WHERE RRO_SHIFT_ID = @RRO_SHIFT_ID;

  -- налоговые ставки
  SELECT @status  = 0
        ,@answer  = ''
        ,@errMessage = ''

  IF EXISTS( SELECT 1 FROM CM_SRRO_TAXES 
                WHERE RRO_SHIFT_ID = @RRO_SHIFT_ID )
    DELETE FROM CM_SRRO_TAXES 
      WHERE RRO_SHIFT_ID = @RRO_SHIFT_ID;

  exec @result = CM_SRRO_API_GET
       @EKKA_ID    = @EKKA_ID
      ,@taskUri    = 'kasa/taxes'
      ,@status     = @status     OUTPUT
      ,@document   = @answer     OUTPUT
      ,@errMessage = @errMessage OUTPUT;

  IF (@result <> 0 OR @status <> 200)
  BEGIN
    SET @MESSAGE = 'Ошибка получения налоговых ставок в РРО';
    EXEC CM_SRRO_HTTP_ERROR  @result, @status, @answer, 
                             @errMessage, 'message', @MESSAGE OUTPUT;
    RAISERROR (@MESSAGE, 16, 1);
  END

  DECLARE tax_20241104_Cursor INSENSITIVE CURSOR FOR
    SELECT json_row
      FROM dbo.GetJsonArray(@answer, 'taxes')

  OPEN tax_20241104_Cursor
  WHILE (1 = 1)
  BEGIN
    FETCH NEXT FROM tax_20241104_Cursor
      INTO @answer;
    IF @@FETCH_STATUS != 0
      BREAK

    SET @TAXES_ID     = CAST(dbo.GetJsonValue( @answer, 'code' ) AS INT);
    SET @TAXES_RATE   = CAST(dbo.GetJsonValue( @answer, 'rate' ) AS MONEY);
    SET @TAXES_SYMBOL = dbo.GetJsonValue( @answer, 'symbol' );

    INSERT INTO CM_SRRO_TAXES 
              (RRO_SHIFT_ID, TAXES_ID, TAXES_RATE, TAXES_SYMBOL)
      VALUES (@RRO_SHIFT_ID, @TAXES_ID, @TAXES_RATE, @TAXES_SYMBOL);
  END
  CLOSE tax_20241104_Cursor
  DEALLOCATE tax_20241104_Cursor         
END TRY
BEGIN CATCH
  SET @MESSAGE = ERROR_MESSAGE()
  RETURN 1;
END CATCH

RETURN 0;
----------------------------------------------------------
END;
GO

GRANT EXECUTE ON CM_SRRO_SHIFT_TAX TO role_TWapp;
GO
