IF OBJECT_ID('dbo.CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE', 'P') > 0
    DROP PROCEDURE dbo.CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE;
GO

-- ================================================================
-- Name: PROCEDURE CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE  
-- Description: Добавить партии товара в акт переоценки, где партии со сроком меньшим, чем указано в константе
-- Author: Lukin E.V.
-- Release: 18.05.2026 Lukin E.V.
-- Changelog:
-- ================================================================
CREATE PROCEDURE CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE
	@id_link    T_IDENTIFIER,
	@id_prime   T_DOCUMENT_ID ,
	@id_child   T_DOCUMENT_ID = NULL	
as
begin
	DECLARE
		@UserId							int,
		@result							int,
		@message						varchar(50)    ,
		@type_message					int,

		@main_loc_id					int,
		@main_dep_id					int,
		@main_subdep_id					int,
		@main_sect_id					int,
		@docum_id						int,

		@LINE_PLU_ID					T_PLU          ,
		@LINE_CNS_ID					T_CONSIGNMENT  ,
		@LINE_NAME						T_NAME_LONG    ,
		@LINE_UNIT						T_METRIC_ID    ,
		@LINE_PRICE_HOME				T_COST,
		@LINE_PRICEFULL_HOME			T_COST,
		@LINE_PRICE_MAIN				T_COST,
		@LINE_PRICEFULL_MAIN			T_COST,

		@DOCUM_DATE						datetime,  
		@RATE_HOME_TO_MAIN				T_CURRENCY_RATE,
		@REASON_ID						int,
		@CURR_HOME						int,
		@CURR_MAIN						int,
		@SELFENTER_ID					int,
		@iret							int,
		@LINE_NUMBER					int,

		@CNS_COST_HOME					T_COST,
		@CNS_COST_MAIN					T_COST,
		@CNS_COSTFULL_HOME				T_COST, 
		@CNS_COSTFULL_MAIN				T_COST,	

		@LINE_OVERPRICE_DISCOUNT		money,
		@LINE_OVERPRICE_INCOUNT			money,
		@PRECISION						int,
		@DOCUM_TAX_PROCENT				money,
		
		@header_doc    					NVARCHAR(max),
		@body_doc   					NVARCHAR(max),
		@recipients						NVARCHAR(max),
		@error							NVARCHAR(max),
		@DEPARTMENT_ID					INT,
		@CNS_DT_MAXSALE date,
		@MONTH_EXPIRED money = 5 -- срок годности;

	select @MONTH_EXPIRED = cu.CONSTUSER_VALUE 
	from CONSTANTS_USER cu
	where cu.CONSTUSER_ID = 'STOCK_LIMITED_LIFE';
	
	IF OBJECT_ID('tempdb..#tbl_cns') IS NOT NULL
    BEGIN
        DROP TABLE #tbl_cns;
    END;
	
	CREATE TABLE #tbl_cns (
		PLU_ID varchar(15),
		CNS_ID int,	
		DEPARTMENT_ID int,
		CNS_COST_HOME money, 
		CNS_COST_MAIN money, 
		CNS_COSTFULL_HOME money, 
		CNS_COSTFULL_MAIN money,
		CNS_DT_MAXSALE date

	);

	create nonclustered index nci_dep on #tbl_cns (CNS_DT_MAXSALE asc, DEPARTMENT_ID asc);

	declare @tbl_result table(
		docum_id int,
		plu_id varchar(15),
		plu_name varchar(240),
		cns_id int,
		CNS_DT_MAXSALE date
	);
	
	with tbl_cns_full_list as (-- список партий с остатками с закупочной
		select c.CNS_ID, c.PLU_ID, c.CNS_DOC_DATE, c.CNS_COST_HOME, c.CNS_COST_MAIN, c.CNS_COSTFULL_HOME, c.CNS_COSTFULL_MAIN, p.DEPARTMENT_ID, c.CNS_DT_MAXSALE
		FROM PLU p 
		join CONSIGNMENT c on c.PLU_ID = p.PLU_ID and c.CNS_QUAN_ONHAND > 0 AND c.CNS_COSTFULL_HOME <> 0 and c.CNS_DT_MAXSALE > '2020-01-01' 
			and c.CNS_DT_MAXSALE < DATEADD(MONTH, @MONTH_EXPIRED  , cast(GETDATE() as date)) 
			and c.CNS_DOC_DATE >= '2020-01-01'
		where p.DEPARTMENT_ID not in (0, 49, 64, 67, 70, 71, 72)
	)
	insert into #tbl_cns(PLU_ID, CNS_ID, DEPARTMENT_ID, CNS_COST_HOME, CNS_COST_MAIN, CNS_COSTFULL_HOME, CNS_COSTFULL_MAIN, CNS_DT_MAXSALE)
	select rtrim(fl.PLU_ID) as PLU_ID, fl.CNS_ID, fl.DEPARTMENT_ID, fl.CNS_COST_HOME, fl.CNS_COST_MAIN, fl.CNS_COSTFULL_HOME, fl.CNS_COSTFULL_MAIN, fl.CNS_DT_MAXSALE
	from tbl_cns_full_list fl
	
	SET @result = 0
	SET @REASON_ID = 7  -- "УЦЕНКА"

	SET @main_loc_id     = 1
	SET @main_dep_id     = 3
	SET @main_subdep_id  = 0
	SET @main_sect_id    = 0

	SELECT @CURR_HOME = CAST(CONST_VALUE AS INT) FROM CONSTANTS WHERE CONST_ID = 'IdCurrHome'
	SELECT @CURR_MAIN = CAST(CONST_VALUE AS INT) FROM CONSTANTS WHERE CONST_ID = 'IdCurrMain'

	SET @DOCUM_DATE = GETDATE()

	SELECT TOP 1 @SELFENTER_ID  = SELFENTER_ID
	FROM LOCATION 
	WHERE LOCATION_ID = @main_loc_id

	-- получаем курс на дату создания акта и вносим его в документ
	EXEC GET_RATE
			@DateTimeNow = @DOCUM_DATE,
			@CurrencyId  = @CURR_HOME,
			@MAIN_Main   = @RATE_HOME_TO_MAIN OUTPUT
    
	--********************************
	-- разбивка по группам товара
	declare cr_dep cursor local fast_forward for
		select distinct tc.DEPARTMENT_ID from #tbl_cns tc
		order by tc.DEPARTMENT_ID

	open cr_dep 
	fetch next from cr_dep
	into @DEPARTMENT_ID

	while @@FETCH_STATUS = 0 
	begin
		-- создание документа
		EXEC @IRET = CREATE_DOC_HOME
		@SELFENTER_ID         = @SELFENTER_ID,
		@TDOC_ID  = 23,
		@LOCATION_ID          = @main_loc_id,
		@LOCATION_DEP_ID      = @main_dep_id,
		@LOCATION_SUBDEP_ID   = @main_subdep_id,
		@LOCATION_SECT_ID     = @main_sect_id,
		@DOCUM_STATE          = 3,     
		@DOCUM_ID = @docum_id OUTPUT

		IF @@ERROR <> 0 OR @IRET <> 0 OR ISNULL(@docum_id, 0) <= 0
		BEGIN
			SET @result       = 100 + @IRET
			SET @message      = 'Ошибка! Не удалось создать новый акт переоценки.'
			SET @type_message = 16
		END  

		UPDATE op
		SET ACTOVER_RATE_MAIN_TO_HOME = @RATE_HOME_TO_MAIN,
			REASON_ID = @REASON_ID,
			DOCUM_BASIS = 'срок ' + d.DEPARTMENT_NAME
		from OVERVALUE_PRICE op
		join DEPARTMENT d on d.DEPARTMENT_ID = @DEPARTMENT_ID and d.DEPARTMENT_SECT_ID = 0 and d.DEPARTMENT_SUB_ID = 0
		WHERE DOCUM_ID = @docum_id

		declare cr_doc_line cursor local fast_forward for
			select t.PLU_ID, t.CNS_ID, p.PLU_NAME, p.METRIC_ID, 
				t.CNS_COST_HOME, t.CNS_COST_MAIN, t.CNS_COSTFULL_HOME, 
				t.CNS_COSTFULL_MAIN, t.CNS_DT_MAXSALE 
			from #tbl_cns t
			join PLU p on p.PLU_ID = t.PLU_ID
			where t.DEPARTMENT_ID = @DEPARTMENT_ID
			order by p.PLU_NAME asc
		
		open cr_doc_line
		fetch next from cr_doc_line
		into @LINE_PLU_ID, @LINE_CNS_ID, @LINE_NAME, @LINE_UNIT, @CNS_COST_HOME, @CNS_COST_MAIN, @CNS_COSTFULL_HOME, @CNS_COSTFULL_MAIN, @CNS_DT_MAXSALE

		SET @LINE_NUMBER = 1
		
		while @@FETCH_STATUS = 0 
		begin
			--обрежем кол-во строк
			if @LINE_NUMBER > 32000
			begin
				set @LINE_NUMBER = 1
				break
			end

			insert into @tbl_result(docum_id, plu_id, plu_name, CNS_DT_MAXSALE, cns_id)
			values(@docum_id, @LINE_PLU_ID, @LINE_NAME, @CNS_DT_MAXSALE, @LINE_CNS_ID);

			EXEC @IRET = INSERT_STOCK_BY_PLU
				@PLU_ID = @LINE_PLU_ID, 
				@LOCATION_ID        = @main_loc_id,
				@LOCATION_DEP_ID    = @main_dep_id,
				@LOCATION_SUBDEP_ID = @main_subdep_id,
				@LOCATION_SECT_ID   = @main_sect_id 

			IF NOT EXISTS (SELECT TOP 1 1 FROM STOCK_CONSIGNMENT
								WHERE CNS_ID = @LINE_CNS_ID
								AND LOCATION_ID         = @main_loc_id 
								AND LOCATION_DEP_ID     = @main_dep_id 
								AND LOCATION_SUBDEP_ID  = @main_subdep_id 
								AND LOCATION_SECT_ID    = @main_sect_id
						)
			BEGIN
				INSERT INTO STOCK_CONSIGNMENT
				( CNS_ID,    PLU_ID,   LOCATION_ID,       LOCATION_DEP_ID,
					LOCATION_SUBDEP_ID,  LOCATION_SECT_ID,  STOCK_CN_DOC_DATE,
					STOCK_CN_QUAN_BEGIN, STOCK_CN_PRICE_HOME, STOCK_CN_PRICEFULL_HOME, STOCK_CN_PRICE_MAIN, STOCK_CN_PRICEFULL_MAIN )
				VALUES (
					@LINE_CNS_ID,  @LINE_PLU_ID,  @main_loc_id, @main_dep_id,
					@main_subdep_id, @main_sect_id, @DOCUM_DATE,
					0 , 0, 0, 0, 0)
			END
 
			EXEC COST_OVERCOST_LINE 
				@plu    = @LINE_PLU_ID ,
				@loc_id = @main_loc_id ,
				@dep_id = @main_dep_id ,
				@sdep_id= @main_subdep_id          ,
				@sect_id= @main_sect_id,
				@operation          = 4  ,
				@retail_h           = @LINE_PRICE_HOME     OUTPUT,
				@retailfull_h       = @LINE_PRICEFULL_HOME OUTPUT,
				@retail_m           = @LINE_PRICE_MAIN     OUTPUT,
				@retailfull_m       = @LINE_PRICEFULL_MAIN OUTPUT,
				@rate_home_to_main  = @RATE_HOME_TO_MAIN,
				@id_home= @CURR_HOME ,
				@id_main= @CURR_MAIN ,
				@new_value          = @CNS_COSTFULL_MAIN 


			EXEC @IRET = CALC_EXTRA_4_LINE_ACTOVER
				@LINE_PLU_ID  = @LINE_PLU_ID ,
				@LINE_PRICEFULL_HOME      = @LINE_PRICEFULL_HOME,
				@LINE_PRICEFULL_MAIN      = @LINE_PRICEFULL_MAIN,
				@LINE_OLD_RETAILFULL_HOME = @LINE_PRICEFULL_HOME     ,
				@LINE_OLD_RETAILFULL_MAIN = @LINE_PRICEFULL_MAIN     ,
				@LINE_COSTFULL_HOME       = @CNS_COSTFULL_HOME      ,
				@LINE_COSTFULL_MAIN       = @CNS_COSTFULL_MAIN      ,
				@LINE_OVERPRICE_DISCOUNT  = @LINE_OVERPRICE_DISCOUNT  OUTPUT , -- изменение цены
				@LINE_OVERPRICE_INCOUNT   = @LINE_OVERPRICE_INCOUNT   OUTPUT   -- наценка
  
			insert into LINE_OVERVALUE_PRICE
				(DOCUM_ID, LINE_NUMBER, LINE_TYPE, LINE_PLU_ID, LINE_IN_OUT,
					LINE_NAME, LINE_UNIT, LINE_QUAN, 
					LINE_PRICE_HOME, LINE_PRICEFULL_HOME, LINE_PRICE_MAIN, LINE_PRICEFULL_MAIN, LINE_DONE, 
					LINE_OLD_RETAIL_HOME, LINE_OLD_RETAILFULL_HOME, LINE_OLD_RETAIL_MAIN, LINE_OLD_RETAILFULL_MAIN,
					LINE_CNS_ID, LINE_LOC_ID, LINE_DEP_ID, LINE_SUBDEP_ID,
					LINE_SECT_ID, LINE_QUAN_DISTRIB, OVERPRICE_STOCKNOTEMPTY,
					LINE_OVERCOST_HOME, LINE_OVERCOST_MAIN,
					LINE_OVERCOSTFULL_HOME, LINE_OVERCOSTFULL_MAIN,
					LINE_OVERPRICE_DISCOUNT, LINE_OVERPRICE_INCOUNT )
			values
				(@docum_id, @LINE_NUMBER, 0, @LINE_PLU_ID, 1,
					@LINE_NAME, @LINE_UNIT, 0, 
					@LINE_PRICE_HOME, @LINE_PRICEFULL_HOME, @LINE_PRICE_MAIN, @LINE_PRICEFULL_MAIN, 0,
					@LINE_PRICE_HOME, @LINE_PRICEFULL_HOME, @LINE_PRICE_MAIN, @LINE_PRICEFULL_MAIN,  
					@LINE_CNS_ID, @main_loc_id, @main_dep_id, @main_subdep_id,  @main_sect_id, 
					0, 1,
					@CNS_COST_HOME, @CNS_COST_MAIN,
					@CNS_COSTFULL_HOME, @CNS_COSTFULL_MAIN,
					@LINE_OVERPRICE_DISCOUNT, @LINE_OVERPRICE_INCOUNT )

			IF @@ERROR <> 0 OR @IRET <> 0
			BEGIN
				SET @result       = 100 + @IRET
				SET @message      = 'Ошибка! Не удалось произвести пересчет количества товара по строке для артикула - ' + @LINE_PLU_ID + '.'
				SET @type_message = 16
				BREAK
			END

			SET @LINE_NUMBER = @LINE_NUMBER + 1 
			
			fetch next from cr_doc_line
			into @LINE_PLU_ID, @LINE_CNS_ID, @LINE_NAME, @LINE_UNIT, @CNS_COST_HOME, @CNS_COST_MAIN, @CNS_COSTFULL_HOME, @CNS_COSTFULL_MAIN, @CNS_DT_MAXSALE
		end

		close cr_doc_line
		deallocate cr_doc_line

		-- пересчет суммы документа
		SELECT @PRECISION = CURR_PREC-3 FROM CURRENCY WHERE CURR_ID = @CURR_HOME

		exec @IRET = CALC_DOC_SUMM_FOR_OverPrice
				@DOCUM_ID          = @docum_id,
				@DOCUM_TAX_PROCENT = @DOCUM_TAX_PROCENT,
				@DOCUM_HOME_CURR   = @CURR_HOME,
				@DOCUM_MAIN_CURR   = @CURR_MAIN,
				@PRECISION         = @PRECISION
		
		IF @@ERROR <> 0 OR @IRET <> 0
		BEGIN
			SET @result       = 100 + @IRET
			SET @message      = 'Ошибка! Не удалось пересчитать сумму акта переоценки.'
			SET @type_message = 16
		END
			
		fetch next from cr_dep
		into @DEPARTMENT_ID
	end

	close cr_dep
	deallocate cr_dep		
	--********************************
	-- разбивка по группам товара

		

	declare @lines_var NVARCHAR(max);

	set @body_doc = '';
	set @lines_var = '';

	--заголовок таблицы
	select distinct 
		@lines_var += '<br><br><table border="1" width="850px"><caption class="cap1"> акт №'+ op.DOCUM_NUMB + ' от ' + format(op.DOCUM_DATE,'dd-MM-yyyy HH:mm:ss') + ' &nbsp;&nbsp;' + op.DOCUM_BASIS + '</caption>'
	from @tbl_result t
	join OVERVALUE_PRICE op on op.DOCUM_ID  = t.docum_id
		

	--строки акта
	set @lines_var += '<tr><td class="sku">Артикул</td><td class="sku">Партия</td><td>Наименование</td><td class="price">Коэффициент</td></tr>'
		
	select  
		@lines_var +=  '<tr><td class="sku">' + rtrim(tbl.plu_id) + '</td><td class="sku">' + rtrim(tbl.cns_id) + '</td><td>' + tbl.plu_name + '</td><td class="price">' + CAST(tbl.CNS_DT_MAXSALE AS varchar(50)) + '</td></tr>'
	from (
		select distinct t.plu_id, t.plu_name, t.cns_id, t.CNS_DT_MAXSALE
		from @tbl_result t
	)tbl
	order by tbl.plu_name asc 

	set @body_doc += @lines_var + '</table>';

	set @lines_var = ''
	
		
	
	
	--********************************************************
	--отправка на email
	set @header_doc = '<!DOCTYPE html> <html lang="ua"> <head> <meta charset="UTF-8"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <title>Переоценки при измененении цен закупки</title><style> table, td { border: 1px solid black; border-collapse: collapse; padding: 4px } .sku { text-align: right; vertical-align: center; width: 80px;} .price { text-align: right; vertical-align: center; width: 80px;} .cap1 { text-align: left; } .header { text-align: center; font-weight: bold; } </style></head><body>';
	set @body_doc = cast((@header_doc + @body_doc + '</body></html>') as nvarchar(max))
	
	--SELECT @recipients = CONSTUSER_VALUE
	--FROM CONSTANTS_USER
	--WHERE CONSTUSER_ID = 'MAIL_OVERPRICE'

	--EXEC @result = CM_BOT_SendEMail @recipients = @recipients
	--								, @CC  = ''
	--								, @BCC = ''
	--								, @subject = 'Рассылка "Переоценки при измененении цен закупки"'
	--								, @body    = @body_doc 
	--								, @error   = @error OUTPUT
	--print @error

	--select @body_doc
	--конец отправка на email
	--*****************************************************

	UPDATE #link_temp SET
	result   = @result  ,
	  id_prime = @id_prime,
	  id_child = @id_child,
	  message  = @message,
	  type_message = @type_message
	WHERE id_link = @id_link

	return 0

end
GO

GRANT EXECUTE ON CM_OVERPRICE_FROM_STOCK_LIMITED_LIFE TO role_TWapp
GO