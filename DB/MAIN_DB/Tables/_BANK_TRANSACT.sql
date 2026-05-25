if object_id('dbo._BANK_TRANSACT', 'U') is not null
  drop TABLE [dbo].[_BANK_TRANSACT]
GO
-- ==========================================================
-- Name: _BANK_TRANSACT
-- Description: Таблица банковских транзакций
-- RELEASE: 03.06.2020
-- Author: Lukin E.V.
-- Changelog:
-- ==========================================================
CREATE TABLE [dbo].[_BANK_TRANSACT](
	[client_mfo] [VARCHAR](6) NULL,
	[client_okpo] [VARCHAR](10) NULL,
	[client_name] [VARCHAR](250) NULL,
	[client_acc] [VARCHAR](29) NULL,
	[payment_type] [INT] NULL,
	[payment_date] [DATETIME] NOT NULL,
	[payment_amount] [DECIMAL](19, 9) NULL,
	[owner_acc] [VARCHAR](29) NULL,
	[doc_ref] [VARCHAR](20) NOT NULL,
	[description] [VARCHAR](1000) NULL,
	[status] [INT] NOT NULL DEFAULT 0,
	[client_bank] [VARCHAR](80) NULL
) ON [PRIMARY]
GO