-- ==========================================================
-- Trigger: TRIGGER trig_CM_HYST_COST_AVG_d
-- Description: Триггер сохранения истории скользящей средней учетной цены при удалении записи 
-- Author: star
-- Release: 06.05.2026 star
-- ==========================================================
CREATE OR ALTER TRIGGER trig_CM_HYST_COST_AVG_d ON CM_HYST_COST_AVG
  FOR DELETE
AS
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM deleted)
  RETURN;

INSERT INTO CM_HYST_COST_AVG_DEL 
       ( HYST_COST_ID      , PLU_ID            , HYST_COST_DT ,
         HYST_COST_DOC_TYPE, HYST_COST_DOC_ID  , HYST_COST_AVG,
         NEXT_COST_DT      )
  SELECT HYST_COST_ID      , PLU_ID            , HYST_COST_DT ,
         HYST_COST_DOC_TYPE, HYST_COST_DOC_ID  , HYST_COST_AVG,
         NEXT_COST_DT      
    from DELETED;
-- ---------------------------------------------------------------
GO

