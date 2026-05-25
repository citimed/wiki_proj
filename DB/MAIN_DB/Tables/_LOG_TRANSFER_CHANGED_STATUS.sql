IF OBJECT_ID('dbo._LOG_TRANSFER_CHANGED_STATUS', 'U') > 0
    DROP TABLE dbo._LOG_TRANSFER_CHANGED_STATUS;
GO

-- ==========================================================
-- Name: TABLE _LOG_TRANSFER_CHANGED_STATUS
-- Description: журнал фиксация измененией возвратного перемещения для синхронизации с БД аптек
-- AUTHOR: Lukin E.V.
-- RELEASE:30.08.2021 Lukin E.V.
-- Changelog:
-- ==========================================================

CREATE TABLE dbo._LOG_TRANSFER_CHANGED_STATUS
(
    DOCUM_ID    INT         NOT NULL
        DEFAULT 0,
    DOCUM_NUMB  VARCHAR(15) NOT NULL
        DEFAULT '',
    SYNC_STATUS INT
        DEFAULT 0,
    LOCATION_ID INT         NOT NULL
        DEFAULT 0,
    OPER_STATUS INT         NOT NULL
        DEFAULT 0,
    TRAS_HASH   INT,
    CREATE_DATE DATETIME    NOT NULL
        DEFAULT GETDATE(),
    SYNC_DATE   DATETIME    NULL
);

GO

CREATE CLUSTERED INDEX [IND_DOCUM_ID]
    ON [dbo].[_LOG_TRANSFER_CHANGED_STATUS] ([DOCUM_ID] ASC)
    WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF,
        ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON
    );

GO


CREATE NONCLUSTERED INDEX IND_SYNC_LOCATION
    ON dbo._LOG_TRANSFER_CHANGED_STATUS (
    SYNC_STATUS,
    LOCATION_ID
)   ;

GO
GRANT ALTER ON dbo._LOG_TRANSFER_CHANGED_STATUS TO [role_TWapp];
GO