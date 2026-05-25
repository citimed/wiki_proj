IF OBJECT_ID('API_GET_AP_LIST', 'TF') IS NOT NULL
    DROP FUNCTION API_GET_AP_LIST;
GO

-- ==========================================================
-- Name: FUNCTION API_GET_AP_LIST
-- Description: Функция получения списка аптек для аггрегаторов
-- Author: Lukin E.V.
-- Release: 10.04.2024
-- Changelog:
-- * 17.04.2026 Lukin E.V. - добалвены поля rp_name, rp_address
-- * 28.10.2024 Lukin E.V. - исправлен запрос
-- * 05.09.2024 Lukin E.V. - добавлен параметр @serviceId - код внешнего сервиса. 
-- ==========================================================

CREATE FUNCTION API_GET_AP_LIST(@serviceId int )

RETURNS @Table_Var TABLE
(
    [password]          varchar(50),
    [server]			varchar(240),
    [database_name]     varchar(15),
    location_id         int,
    service_rempoint_id varchar(15),
    rempoint_id			varchar(15),
	rp_name				varchar(80),
	rp_address			varchar(255)
)
AS
BEGIN;
	if coalesce(@serviceId, 0) = 0
		set @serviceId = 1;

    insert into @Table_Var(password, server, database_name, location_id, service_rempoint_id, rempoint_id, rp_name, rp_address)
	SELECT rp.REMPOINT_PATH_ERROR AS password, rp.REMPOINT_PATH_ARCHIV AS server,
		REPLACE(rp.REMPOINT_ID, 'A', 'AP') AS database_name, rp.LOCATION_ID as location_id, 
		COALESCE(link.SERVICE_REMPOINT_ID, '') AS service_rempoint_id, rp.REMPOINT_ID as rempoint_id,
		RTRIM(rp.REMPOINT_NAME) AS RP_NAME,
        RTRIM(rp.REMPOINT_PATH_IMPORT) AS RP_ADDRESS
	FROM dbo._SERVICES s
	JOIN dbo._LINK_SERVICES_TO_REMOTE_POINTS link ON link.SERVICE_ID = s.ID
	join dbo.REMOTE_POINT rp on rp.REMPOINT_ID = link.REMPOINT_ID AND COALESCE(rp.REMPOINT_PATH_ARCHIV, '') <> ''
	where s.ID = @serviceId
	order by RTRIM(rp.REMPOINT_NAME) asc

    RETURN;
END;

GO