IF OBJECT_ID('LINK_SALE_CREATE_CASH_MARKETING', 'P') > 0
	DROP PROCEDURE LINK_SALE_CREATE_CASH_MARKETING;
GO
-- ===============================================================
-- Name: PROCEDURE LINK_SALE_CREATE_CASH_MARKETING
-- Description: Процесс создания приходного кассового ордера из расходной накладной для списания маркетинга
-- Author: Lukin E.V.
-- Release: 20.03.2026
-- Changelog:
-- * 30.03.2026 Lukin E.V. - дата акта = дата накладной
-- * 01.05.2026 Lukin E.V. - добавлена проверка на роль пользователя ROLE_ID IN (1,7,25,30)
-- ===============================================================
CREATE PROCEDURE [dbo].[LINK_SALE_CREATE_CASH_MARKETING]
  @id_link    T_IDENTIFIER,
  @id_prime   T_DOCUMENT_ID,
  @id_child   T_DOCUMENT_ID = null
AS
begin
	
	
	


	
	DECLARE
		@result int,
		@message varchar(500),
		@DOCUM_ID int,
		@DOCUM_DATE datetime,
		@AUTHOR_ID int;

	exec GET_AUTHORID  @AUTHOR_ID = @AUTHOR_ID OUTPUT;

	

	IF NOT EXISTS(
					SELECT r.ROLE_ID,  r.ROLE_NAME FROM AP_ROLE r
					JOIN dbo.USER_ROLE u ON u.ROLE_ID = r.ROLE_ID AND u.USER_ID = @AUTHOR_ID
					WHERE r.ROLE_ID IN (1,7,25,30)
					)
	BEGIN
	  SET @result = 1  
	  SET @message = 'Нет доступа на выполнение данного процесса!'
	  GOTO finish;
	END
	
	exec @result =  dbo.LINK_SALE_CREATE_CASH
		@id_link    = 15021,
		@id_prime   = @id_prime,
		@id_child   = @DOCUM_ID OUTPUT;

	if @result > 0
		goto finish
	
	if @DOCUM_ID > 0  
	begin
		update dc set 
			dc.CASHLIST_ID = 5, dc.DOCUM_NUMB = 'МРС-' + dc.DOCUM_NUMB, 
			ENTERPRISE_ID = (select ENTERPRISE_ID from SALE where DOCUM_ID = @id_prime), 
			FD_CLASS_ID = 103,
			dc.DOCUM_DATE = s.DOCUM_DATE
		from DOC_CASH dc
		join SALE s on s.DOCUM_ID = @id_prime and s.TDOC_ID = 15
		where dc.docum_id = @DOCUM_ID

		--свяжем с накладной
		insert into LINK_DOC(LINKDOC_MAIN_TYPE, LINKDOC_MAIN_ID, LINKDOC_DEPEND_TYPE, LINKDOC_DEPEND_ID)
		values (15, @id_prime, 20, @DOCUM_ID )			
	end
	
	finish:

	UPDATE #link_temp SET
		result   = @result  ,
		id_prime = @id_prime,
		id_child = @id_child,
		message  = @message
	WHERE id_link = @id_link

	return @result
end

GO

GRANT EXECUTE ON LINK_SALE_CREATE_CASH_MARKETING TO role_TWapp
GO