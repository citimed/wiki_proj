---
type: trigger
db_version: MS SQL Server 2019
dialect: T-SQL
---

# 🪤 dbo.trig_STOCK_u_Free (Триггер)

## 📄 Метаданные
```text
NAME   : TRIGGER trig_STOCK_u_Free
Description: Отслеживание интегральных количеств по артикулу и размещениям
(Пересчет свободного количества в STOCK)
(Вызов Update_Plu_Qty, которая отражает изменения STOCK в таблице PLU_QUANTITY)
Author : alex
Release: 29.04.02
Changelog:
16.11.02 star
23.12.2003 aba
Раньше Update_Plu_Qty запускалась только при изменении QUAN_ONHAND,QUAN_DISTRIB,QUAN_WAIT.
Добавлен вызов по изменению QUAN_REQUEST,QUAN_MIN, любой из стоимостей PLU.
28.01.2004 - Оптимизирован Код.
28.07.04 star - восстановлен расчет сумм по количествам по размещениям
29.08.05 kaa - запуск UPDATE_PLU_STOCK_SUMQUAN при изм. STOCK_QUAN_RESERV
03.10.05 star - STOCK_QUAN_FREE = STOCK_QUAN_ONHAND - STOCK_QUAN_DISTRIB - STOCK_QUAN_RESERV
08.12.05 star - контроль STOCK_CN_QUAN_FREE
22.04.05 star - STOCK_QUAN_FREE = STOCK_QUAN_ONHAND - STOCK_QUAN_DISTRIB
09.08.08 star - контроль за отриц. STOCK_QUAN_RESERV
29.12.25 star - замена UPDATE_PLU_QTY на CALC_ONE_PLU_QUAN
```

## 🔗 Связи
* **Связан с сущностью:** `[[AS]]`
* **Связан с сущностью:** `[[INSERTED]]`
* **Связан с сущностью:** `[[STOCK]]`