IF OBJECT_ID('CM_SRRO_SAVELOG', 'P') IS NOT NULL
    DROP PROCEDURE CM_SRRO_SAVELOG;
GO

--------------------------------------------------------
-- NAME   : PROCEDURE CM_SRRO_SAVELOG
-- NOTE   : Логируем в SQL Server Log и Windows Event Viewer
-- CREATE : 20.02.2026 star
----------------------------------------------------------
CREATE PROCEDURE CM_SRRO_SAVELOG
  @MESSAGE  NVARCHAR(2048)
WITH EXECUTE AS OWNER
AS
BEGIN
SET NOCOUNT ON;
DECLARE
  @Severity        VARCHAR(10) = 'Warning'
, @CustomErrorCode INT     = 50010     -- код для ПРРО
;
SET @MESSAGE = 'SRRO: '+ @MESSAGE;
EXEC xp_logevent @CustomErrorCode, @MESSAGE, @Severity;

RETURN 0;
----------------------------------------------------------
END;
GO

GRANT EXECUTE ON CM_SRRO_SAVELOG TO role_TWapp;
GO
