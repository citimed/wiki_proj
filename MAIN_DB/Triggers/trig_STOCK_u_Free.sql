-- ==========================================================
-- NAME   : TRIGGER trig_STOCK_u_Free
-- Description: Отслеживание интегральных количеств по артикулу и размещениям
--          (Пересчет свободного количества в STOCK)
--          (Вызов Update_Plu_Qty, которая отражает изменения STOCK в таблице PLU_QUANTITY)
-- Author : alex
-- Release: 29.04.02
-- Changelog:
-- 16.11.02 star
-- 23.12.2003 aba
--          Раньше Update_Plu_Qty запускалась только при изменении QUAN_ONHAND,QUAN_DISTRIB,QUAN_WAIT.
--          Добавлен вызов по изменению QUAN_REQUEST,QUAN_MIN, любой из стоимостей PLU.
-- 28.01.2004 - Оптимизирован Код.
-- 28.07.04 star - восстановлен расчет сумм по количествам по размещениям
-- 29.08.05 kaa - запуск UPDATE_PLU_STOCK_SUMQUAN при изм. STOCK_QUAN_RESERV
-- 03.10.05 star - STOCK_QUAN_FREE = STOCK_QUAN_ONHAND - STOCK_QUAN_DISTRIB - STOCK_QUAN_RESERV
-- 08.12.05 star - контроль STOCK_CN_QUAN_FREE
-- 22.04.05 star - STOCK_QUAN_FREE = STOCK_QUAN_ONHAND - STOCK_QUAN_DISTRIB
-- 09.08.08 star - контроль за отриц. STOCK_QUAN_RESERV
-- 29.12.25 star - замена UPDATE_PLU_QTY на CALC_ONE_PLU_QUAN
-- ==========================================================
ALTER TRIGGER trig_STOCK_u_Free ON STOCK
 FOR INSERT, UPDATE
AS

DECLARE @PLU_ID             T_PLU
DECLARE @LOCATION_ID        T_LOCATION_ID
DECLARE @LOCATION_DEP_ID    T_LOCATION_ID
DECLARE @LOCATION_SUBDEP_ID T_LOCATION_ID
DECLARE @LOCATION_SECT_ID   T_LOCATION_ID
DECLARE @Update1            T_FLAG
DECLARE @Update2            T_FLAG
DECLARE @STOCK_QUAN_RESERV  money

select @Update1=0, @Update2=0

IF UPDATE (STOCK_QUAN_DISTRIB) OR UPDATE (STOCK_QUAN_ONHAND) 
 Set @Update1 = 1

IF UPDATE (STOCK_QUAN_REQUEST) OR UPDATE (STOCK_QUAN_MIN) OR 
   UPDATE (STOCK_COST_MAIN)    OR UPDATE (STOCK_COSTFULL_MAIN) OR 
   UPDATE (STOCK_COST_HOME)    OR UPDATE (STOCK_COSTFULL_HOME) OR 
   UPDATE (STOCK_QUAN_RESERV)
 Set @Update2=1

IF @Update1+@Update2=0 RETURN

SELECT @PLU_ID  = PLU_ID,
       @LOCATION_ID = LOCATION_ID,
       @LOCATION_DEP_ID = LOCATION_DEP_ID,
       @LOCATION_SUBDEP_ID = LOCATION_SUBDEP_ID,
       @LOCATION_SECT_ID = LOCATION_SECT_ID,
       @STOCK_QUAN_RESERV = STOCK_QUAN_RESERV
  FROM inserted

if UPDATE(STOCK_QUAN_RESERV) and @STOCK_QUAN_RESERV < 0
  UPDATE STOCK
      SET STOCK_QUAN_RESERV = 0
    WHERE  PLU_ID            = @PLU_ID
      AND  LOCATION_ID       = @LOCATION_ID
      AND  LOCATION_DEP_ID   = @LOCATION_DEP_ID
      AND  LOCATION_SUBDEP_ID= @LOCATION_SUBDEP_ID
      AND  LOCATION_SECT_ID  = @LOCATION_SECT_ID


IF @Update1 > 0 
   UPDATE STOCK
      SET STOCK_QUAN_FREE = case when (STOCK_QUAN_ONHAND - STOCK_QUAN_DISTRIB) > 0
                                 then STOCK_QUAN_ONHAND - STOCK_QUAN_DISTRIB
                                 else 0 end 
    WHERE  PLU_ID            = @PLU_ID
      AND  LOCATION_ID       = @LOCATION_ID
      AND  LOCATION_DEP_ID   = @LOCATION_DEP_ID
      AND  LOCATION_SUBDEP_ID= @LOCATION_SUBDEP_ID
      AND  LOCATION_SECT_ID  = @LOCATION_SECT_ID

EXECUTE CALC_ONE_PLU_QUAN @PLU_ID = @PLU_ID, @STOCK_ONLY = 1;

-- суммы по количествам по размещениям
EXECUTE UPDATE_PLU_STOCK_SUMQUAN  @PLU_ID = @PLU_ID, 
     @LOCATION_ID = @LOCATION_ID, @LOCATION_DEP_ID = @LOCATION_DEP_ID,
     @LOCATION_SUBDEP_ID = @LOCATION_SUBDEP_ID, @LOCATION_SECT_ID = @LOCATION_SECT_ID
------------------------------------------------------------------------------------------------------
GO
