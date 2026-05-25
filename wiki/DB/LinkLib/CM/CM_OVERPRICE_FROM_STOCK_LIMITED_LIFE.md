---
type: sql_script
db_version: MS SQL Server 2019
dialect: T-SQL
---

# 📝 dbo.CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE (Скрипт)

## 📄 Метаданные
```text
Name    : PROCEDURE CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE
Description    : Добавить партии товара в акт переоценки, где партии со сроком меньшим, чем указано в константе
Author         : Lukin E.V.
Release        : 18.05.2026 Lukin E.V.
Changelog:
```

## 🔗 Связи
* **Связан с сущностью:** `[[CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE]]`
* **Связан с сущностью:** `[[CONSIGNMENT]]`
* **Связан с сущностью:** `[[CONSTANTS]]`
* **Связан с сущностью:** `[[CONSTANTS_USER]]`
* **Связан с сущностью:** `[[CR_DEP]]`
* **Связан с сущностью:** `[[CR_DOC_LINE]]`
* **Связан с сущностью:** `[[CURRENCY]]`
* **Связан с сущностью:** `[[DEPARTMENT]]`
* **Связан с сущностью:** `[[LINE_OVERVALUE_PRICE]]`
* **Связан с сущностью:** `[[LOCATION]]`
* **Связан с сущностью:** `[[OP]]`
* **Связан с сущностью:** `[[OVERVALUE_PRICE]]`
* **Связан с сущностью:** `[[PLU]]`
* **Связан с сущностью:** `[[STOCK_CONSIGNMENT]]`
* **Связан с сущностью:** `[[TBL_CNS_FULL_LIST]]`