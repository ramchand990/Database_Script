--
-- PostgreSQL database dump
--

-- Dumped from database version 14.5
-- Dumped by pg_dump version 14.2

-- Started on 2023-03-08 12:02:31

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 4896 (class 1262 OID 44555)
-- Name: Prod; Type: DATABASE; Schema: -; Owner: root
--

CREATE DATABASE "Prod" WITH TEMPLATE = template0 ENCODING = 'UTF8' LOCALE = 'en_US.UTF-8';


ALTER DATABASE "Prod" OWNER TO root;

\connect "Prod"

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 10 (class 2615 OID 49307)
-- Name: healspan; Type: SCHEMA; Schema: -; Owner: root
--

CREATE SCHEMA healspan;


ALTER SCHEMA healspan OWNER TO root;

--
-- TOC entry 441 (class 1255 OID 53397)
-- Name: approve_claim(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.approve_claim(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
--select * from healspan.get_next_hs_user(585)
--select * from healspan.approve_claim(605,1,'Approve','dummy')


   declare p_current_hs_user int;
   declare p_assignto_user_id int; 
   declare p_next_status_master_id int;
   declare p_claim_stage_link_id_1 int;
   declare p_maxid int;
   declare v_claim_info_id integer;
   declare v_patient_info_id integer;
   declare v_claim_stage_mst_id integer;
   declare v_flowtype text;
   declare v_transfercomment text;
   declare v_json_response text;
   declare v_nresponse text;
   declare v_doclist text;
   declare v_tpa_response text;
   declare v_package_amount integer;

BEGIN

	create temp table if not exists temp_RESPONSE_json (
			"claimId" INT,
			"claimStageLinkId" INT,
			"responseStatus" TEXT
			)on commit drop;
	
	select x."claimId" ,x."stageId",x."flowType",x."transferComment" into v_claim_info_id,v_claim_stage_mst_id,v_flowtype,v_transfercomment  
			from json_to_record( jsondata::json) AS x(
				
				"claimId" INT,
				"stageId" INT,
				"flowType" text,
				"transferComment" text
			);

------ submit claim
create temp table if not exists temp_current_assigment(
		p_claim_assigment_id int,
		p_claim_stage_link_id int,
		p_status_master_id int
		)on commit drop;


insert into temp_current_assigment
(p_claim_assigment_id,p_claim_stage_link_id,p_status_master_id)
select ca.id, ca.claim_stage_link_id, ca.status_mst_id  
from healspan.claim_assignment ca 
where claim_info_id = v_claim_info_id
and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

---- update current assignment compleated date
update healspan.claim_assignment 
set completed_date_time = now()
where claim_info_id = v_claim_info_id
and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

-- select * from healspan.status_mst sm2 order by 1
------ get next status master id
p_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Pending TPA Approval' 
			);
		
----- get TPA user for assignment
	
p_assignto_user_id := (select id from healspan.user_mst um where user_role_mst_id  = 5 limit 1);


p_claim_stage_link_id_1 := (select p_claim_stage_link_id  from temp_current_assigment);
--p_maxid := (select max(id) + 1 from healspan.claim_assignment);

INSERT INTO healspan.claim_assignment
( assigned_date_time, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
claim_stage_mst_id, user_mst_id, status_mst_id)
select  now(), 5, v_claim_info_id, tmp.p_claim_stage_link_id , 
v_claim_stage_mst_id, p_assignto_user_id, p_next_status_master_id 
from temp_current_assigment tmp;

----------- update stage link
update healspan.claim_stage_link 
set status_mst_id = p_next_status_master_id, user_mst_id = p_assignto_user_id
where id  = p_claim_stage_link_id_1;

v_patient_info_id  := (select patient_info_id  from healspan.claim_stage_link where id = p_claim_stage_link_id_1 limit 1);

---------------------Package amount to pass in TPA response-------------------------
select pol.amount into v_package_amount  from healspan.patient_othercost_link  pol, healspan.other_costs_mst ocm 
where pol.other_costs_mst_id =ocm.id 
and ocm."name" ='Package'
and pol.patient_info_id =v_patient_info_id limit 1;
IF NOT FOUND then
v_package_amount := 0;
END IF;
---------------------------------------------------------------------

select * from healspan.insert_notification(v_claim_info_id, v_claim_stage_mst_id,p_next_status_master_id,0,0) into v_nresponse;


		   ----------------comma saperate doc list in tpa response--------------------
			select string_agg(d."path" ||'/' || d."name", ',') into v_doclist
			from healspan."document" d 
			--left join healspan.claim_stage_link csl on csl.id = d.claim_stage_link_id 
		    where d.claim_stage_link_id = p_claim_stage_link_id_1 ; 
		   
            -----Response parameters to need to send to tpa--------------------------------
			select json_build_object
			     ('itemData',json_build_object(
			      'DeferDate',CURRENT_DATE,
			      'DueDate',CURRENT_DATE,
			      'Priority','Normal',
			      'Name','Postman',
			      'Reference','HealSpan',
			      'SpecificContent',json_build_object(
				  'claimId',csl.claim_info_id,
				  'tpaClaimNumber',ci.tpa_claim_number,
				  'hsClaimNumber',ci.healspan_claim_id , 
				  'claimStageLinkId',csl.id,
				  'responseStatus','SUCCESS',
				  'memberId',ii.tpa_id_card_number ,
				  'tpaName',tm.name,
				  'fullName',concat(pin.first_name, ' ', ltrim(concat(' ', COALESCE(pin.middle_name, ''::character varying), ' ', COALESCE(pin.last_name, ''::character varying)), ' '::text)),
				  'mobileNo',pin.mobile_no,
				  'dateOfAdmission',TO_CHAR(pin.date_of_admission , 'dd-mm-yyyy hh12:mi AM'),
				  'dateOfDischarge',TO_CHAR(pin.estimated_date_of_discharge , 'dd-mm-yyyy hh12:mi AM'),
				  'isDischargeToday',case when  pin.estimated_date_of_discharge::date = CURRENT_DATE::date then 'YES' else 'NO' end,
				  'doctorName',mi.doctor_name,
				  'doctorRegNumber',mi.doctor_registration_number,
				  'roomType',rcm.name,
				  'proposedLineOfTreatment',ttm.name ,
				  'treatment',pm.display_name,
				  'diagnosis',dm.display_name,
			      'roomRentAndNursingCharges',pin.cost_per_day ,
				  'packageAmount',v_package_amount,
				  'stageName',csm."name",
				  'documentList',v_doclist
				 )) ) into v_tpa_response
				  from healspan.claim_stage_link csl 
				 inner join healspan.insurance_info ii on ii.id = csl.insurance_info_id
				 inner JOIN healspan.patient_info pin ON pin.id = csl.patient_info_id
				 inner JOIN healspan.medical_info mi ON mi.id = csl.medical_info_id
				 left join healspan.tpa_mst tm on tm.id = ii.tpa_mst_id 
				 left join healspan.room_category_mst rcm on rcm.id = pin.room_category_mst_id
				 left join healspan.treatment_type_mst ttm on ttm.id = mi.treatment_type_mst_id 
				 left join healspan.procedure_mst pm on pm.id = mi.procedure_mst_id 
				 left join healspan.diagnosis_mst dm on dm.id = mi.diagnosis_mst_id 
				 left join healspan.claim_stage_mst csm on csm.id = csl.claim_stage_mst_id 
				 left join healspan.claim_info ci on ci.id = csl.claim_info_id 
				 where csl.id = p_claim_stage_link_id_1;
	
--	 select v_tpa_response || v_json_doclist into v_json_response;
	
	return v_tpa_response ;
	
----
--insert into temp_RESPONSE_json values (v_claim_info_id,0,'SUCCESS');
--
--SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
--return v_response_message;
--	
END;
$$;


ALTER FUNCTION healspan.approve_claim(jsondata text) OWNER TO root;

--
-- TOC entry 442 (class 1255 OID 53714)
-- Name: change_stage(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.change_stage(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
--select * from healspan.get_next_hs_user(585)

--declare p_current_hs_user int;
declare p_assignto_user_id int; 
declare p_next_status_master_id int;
declare v_claim_info_id int;
declare p_maxid int;
declare p_link_maxid int;
declare v_claim_stage_link_id integer;
declare v_claim_stage_mst_id integer;
declare v_status_mst_id text;
declare v_user_mst_id  text;
declare v_response_message text;
declare v_new_claim_stage_link_id integer;

BEGIN

	create temp table if not exists temp_RESPONSE_json (
			"claimId" INT,
			"claimStageLinkId" INT,
			"responseStatus" TEXT
			)on commit drop;
	
	select x."claimStageLinkId" ,x."claimStageId",x."statusId",x."userId" into v_claim_stage_link_id,v_claim_stage_mst_id,v_status_mst_id,v_user_mst_id  
			from json_to_record( jsondata::json) AS x(
				
				"claimStageLinkId" integer,
				"claimStageId" integer,
				"statusId" integer,
				"userId" integer
			);


--- get claim info id
v_claim_info_id := (select csl.claim_info_id  from healspan.claim_stage_link csl 
where id=v_claim_stage_link_id);



---- update current assignment compleated date
update healspan.claim_assignment 
set completed_date_time = now()
where claim_info_id = v_claim_info_id
--and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

-- select * from healspan.status_mst sm2 order by 1
------ get next status master id
p_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Pending Documents' 
			);
		
----- get Hospital user for assignment
	
p_assignto_user_id := (
		select user_mst_id from healspan.claim_assignment ca , healspan.user_mst um 
		where claim_info_id = v_claim_info_id
		and user_mst_id = um.id 
		and um.user_role_mst_id =2
		order by ca.assigned_date_time desc 
		limit 1
);

--p_link_maxid := (select max(id) + 1 from healspan.claim_stage_link csl);

insert into healspan.claim_stage_link 
( created_date_time , claim_info_id , claim_stage_mst_id , 
insurance_info_id , medical_info_id ,patient_info_id ,status_mst_id ,
user_mst_id )
select  now(),  csl.claim_info_id , v_claim_stage_mst_id,
csl.insurance_info_id , csl.medical_info_id , csl.patient_info_id , p_next_status_master_id,
p_assignto_user_id
from healspan.claim_stage_link	csl 
where id=v_claim_stage_link_id;

v_new_claim_stage_link_id :=(select currval('healspan.claim_stage_link_id_seq'));-- into v_new_claim_stage_link_id ;

-------Inser next stage documents those are not available in document table----------------------`	
INSERT INTO healspan."document"(claim_stage_link_id, mandatory_documents_mst_id, status)
	    SELECT v_new_claim_stage_link_id,sdl.mandatory_documents_mst_id	,false 
        from healspan.stage_and_document_link_mst sdl
		inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  
        where sdl.claim_stage_mst_id = v_claim_stage_mst_id 
			    and sdl.mandatory_documents_mst_id	not in (
			     select d.mandatory_documents_mst_id from healspan."document" d 
					left join healspan.claim_stage_link csl on csl.id = d.claim_stage_link_id 
					where csl.claim_info_id = v_claim_info_id
			    ) order by sdl.mandatory_documents_mst_id ;

---------------------------------------------------------------------------------------------------  

--p_maxid := (select max(id) + 1 from healspan.claim_assignment);

INSERT INTO healspan.claim_assignment
(assigned_date_time, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
claim_stage_mst_id, user_mst_id, status_mst_id)
select now(), 2, v_claim_info_id, v_new_claim_stage_link_id , 
v_claim_stage_mst_id, p_assignto_user_id, p_next_status_master_id ;


insert into temp_RESPONSE_json values (v_claim_info_id,v_new_claim_stage_link_id,'SUCCESS');

SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
return v_response_message;

--return p_assignto_user_id;
	
END;
$$;


ALTER FUNCTION healspan.change_stage(jsondata text) OWNER TO root;

--
-- TOC entry 440 (class 1255 OID 112927)
-- Name: deletedocumentdetails(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.deletedocumentdetails(p_id integer) RETURNS text
    LANGUAGE plpgsql
    AS $$
declare v_response_message text;
	begin
--	  select * from healspan."document";
	 update healspan."document" set is_active ='N'  where id = p_id;
     
	select jsonb_build_object(
	  'responseStatus','SUCCESS'
    ) into v_response_message  ;
   
    return v_response_message;
	END;
$$;


ALTER FUNCTION healspan.deletedocumentdetails(p_id integer) OWNER TO root;

--
-- TOC entry 437 (class 1255 OID 51563)
-- Name: get_claim_details(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_claim_details(v_claimstagelinkid integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
   declare v_json_response jsonb;
   declare v_json_claimassignment jsonb;
   declare v_main_response jsonb;
   declare v_json_doclist jsonb;
   declare v_json_questions jsonb;
   declare v_json_patientothercost jsonb;
   declare v_json_ChronicIllness jsonb;
  
	declare v_patientAndOtherCost jsonb;
	declare v_assignCommentDto jsonb;
	declare v_tpaQueryDto jsonb;
	declare v_claim_info_id INT;
	declare v_patient_info_id int;
	declare v_medical_info_id int;
    declare v_healspan_claim_id text;
begin
--	create temp table if not exists temp_claimstagelist (
--			claim_info_id INT,
--			claim_stage_mst_id INT 
--			);--on commit drop;
--		
--insert into temp_claimstagelist
     	select claim_info_id,patient_info_id,medical_info_id 
		into v_claim_info_id,v_patient_info_id,v_medical_info_id from healspan.claim_stage_link where id = v_claimstagelinkid;
	
		select ci.healspan_claim_id into v_healspan_claim_id 
		from healspan.claim_info ci  
		where ci.id = v_claim_info_id;
		
	-------Get list of healsspan query comments--------------------------------------------------------------
		 select jsonb_agg(json_build_object(
											'claimStageMstId',claim_stage_mst_id ,
											'assignedDateTime',assigned_date_time ,
											'comments',assigned_comments 
											)
								) into v_assignCommentDto from healspan.claim_assignment
									where claim_info_id = v_claim_info_id and assigned_comments is not null;
								-- tpa info query	
   ----------------------------------------------------------------------------------------------------------
		
		
											
		---------------------------------get list of tpa query info------------------------------------						
		select jsonb_agg(json_build_object(
											'claimStageMstId',claim_stage_id ,
											'createdDateTime', created_datetime ,
											'remarks',remarks  
											)
								) into v_tpaQueryDto from healspan.tpa_update tu 
									where claim_info_id = v_claim_info_id  and remarks is not null; --and status in ( 'QUERY', 'REJECTED' );
	-----------------------------------------------------------------------------------------------------
	  --------------------Retrive claim assignment details----------------------------------------------			    
		 select json_build_object(
		    'claimAssignment',json_build_object(
					'id',ca.id ,
					'actionTaken',ca.action_taken ,
					'assignedUserId',null,
					'assignedUser',null,
					'assignedDateTime',ca.assigned_date_time ,
					'assigneeComments',ca.assigned_comments ,
					'completedDateTime',ca.completed_date_time ,
					'claimStageLinkId',ca.claim_stage_link_id ,
					'userMstId',ca.user_mst_id ,
					'claimInfoId',ca.claim_info_id ,
					'claimStageMstId',ca.claim_stage_mst_id ,
					'assignCommentDto',v_assignCommentDto,
					'tpaQueryDto', v_tpaQueryDto
				      ) ) into v_json_claimassignment  
		    from healspan.claim_assignment ca where id = (select max(id) from healspan.claim_assignment ca1 where ca1.claim_stage_link_id = v_claimstagelinkid);
		 ----------------------------------------------------------------------------------------------
		 --------------Retrive document list based on claim info id --------------------------------------
		  select  json_build_object('documentList',json_agg(json_build_object(
							'id',d.id ,
							'documentsMstId',d.mandatory_documents_mst_id ,
							'mandatoryDocumentName',mdm."name",
							'documentName',d."name" ,
							'documentPath',d."path",
							'status',d.status ,
							'claimStageMstId',csl.claim_stage_mst_id,
							'is_deleted',d.is_deleted 
		                ))) into v_json_doclist 
			from healspan."document" d 
			inner join healspan.mandatory_documents_mst mdm on mdm.id = d.mandatory_documents_mst_id 
			left join healspan.claim_stage_link csl on csl.id = d.claim_stage_link_id 
		    where csl.claim_info_id = v_claim_info_id ;
--			where d.claim_stage_link_id = v_claimstagelinkid;
		------------------------------------------------------------------------------------------
		-------------------Retrive questionAnswerList based on claim stage link id--------------------
		
		  select  json_build_object('questionAnswerList',json_agg(json_build_object(
							'id',qa.id ,
							'questions',qa.questions  ,
							'answers',qa.answers ,
							'claimStageLinkId',qa.claim_stage_link_id 
		                ))) into v_json_questions 
			from healspan.question_answer qa 
			inner join healspan.claim_stage_link csl on csl.id = qa.claim_stage_link_id 
			where  csl.id = v_claimstagelinkid;
		---------------------------------------------------------------------------------------------------------
		-------------------Retrive other cost list  based on patient info id-------------------- 
		   select  json_agg(json_build_object(
											'id',pol.other_costs_mst_id ,
											'amount',pol.amount  ,
											'otherCostsMstName',ocm."name"
						                )) into v_json_patientothercost 
				--pol.id,pol.amount ,ocm."name" 
				from healspan.patient_othercost_link pol 
				left join healspan.other_costs_mst ocm on ocm.id = pol.other_costs_mst_id 
				where pol.patient_info_id = v_patient_info_id;
	    --------------------------------------------------------------------------------------------------
		-------------------Retrive chronical illness list  based on claim medical info id--------------------
			select  json_agg(json_build_object(
												'id',mcil.chronic_illness_mst_id  ,
												'chronicIllnessMstName',cim.name  
							                )) into v_json_ChronicIllness 
					from healspan.medical_chronic_illness_link mcil 
					left join healspan.chronic_illness_mst cim on cim.id = mcil.chronic_illness_mst_id 
					where mcil.medical_info_id =v_medical_info_id;
		----------------------------------------------------------------------------------------------------
		-------------------load  claimInfo,patientInfo,medicalInfo,insuranceInfo detail --------------------
					    
		  select json_build_object(
		                'id',csl.id,
		 		        'claimStageMstId',csl.claim_stage_mst_id ,
		 		        'claimStageMstName',csm."name" ,
		 		        'statusMstId',csl.status_mst_id ,
		 		        'statusName',sm.name ,
		 		        'userMstId',csl.user_mst_id ,
		                'claimInfo', json_build_object(
						'id',ci.id,							
						'tpaClaimNumber',ci.tpa_claim_number ,
						'createdDateTime',ci.created_date_time ,
						'claimStageLinkId',csl.id,
						'userId',ci.user_mst_id,
						'hospitalId',ci.hospital_mst_id ,
						'requestType',null,
						'submitted',false,
						'healspanClaimID' , v_healspan_claim_id 
						--'claimStageId',ci.,
		                ),
		                'patientInfo',json_build_object(
					        'id',pin.id ,
					        'claimStageLinkId',csl.id,
					        'isSubmitted',true,
					        'firstName',pin.first_name ,
					        'middleName',pin.middle_name  ,
					        'lastname',pin.last_name  ,
					        'mobileNo',pin.mobile_no  ,
					        'dateBirth',pin.date_of_birth  ,
					        'age',pin.age  ,
					        'isPrimaryInsured',pin.is_primary_insured ,
					        'dateOfAdmission',pin.date_of_admission  ,
					        'estimatedDateOfDischarge',pin.estimated_date_of_discharge ,
					        'dateOfDischarge',pin.date_of_discharge  ,
					        'costPerDay',pin.cost_per_day  ,
					        'totalRoomCost',pin.total_room_cost  ,
					        'otherCostsEstimate',pin.other_costs_estimation  ,
					        'initialCostEstimate',pin.initial_costs_estimation  ,
					        'billNumber',pin.bill_number  ,
					        'claimedAmount',pin.claimed_amount  ,
					        'enhancementEstimate',pin.enhancement_estimation  ,
					        'finalBillAmount',pin.final_bill_amount  ,
					        'patientUhid',pin.patient_uhid  ,
					        'hospitalId',pin.hospital_mst_id ,
					        'hospitalName',hm."name"  ,
					        'hospitalCode',hm.hospital_code ,
					        'patientAndOtherCostLink',v_json_patientothercost,
					        'roomCategoryId',pin.room_category_mst_id,
					        'genderId',pin.gender_mst_id ,
					        'submitted',true,
		        			'primaryInsured',pin.is_primary_insured,
		        			'roomCategoryName',rcm."name" ,
		        			'gender',gm."name" 
		                ),
		                'medicalInfo',json_build_object(
					        'id',mi.id ,
					        'claimInfoId',csl.claim_info_id ,
					        'claimStageId',csl.claim_stage_mst_id ,
					        'claimStageLinkId',csl.id ,
					        'isSubmitted',false,
					        'dateOfFirstDiagnosis',mi.date_of_first_diagnosis ,
					        'doctorName',mi.doctor_name ,
					        'doctorRegistrationNumber',mi.doctor_registration_number ,
					        'doctorQualification',mi.doctor_qualification ,
					        'procedureId',mi.procedure_mst_id ,
					        'procedureName',pm.display_name ,
					        'diagnosisId',mi.diagnosis_mst_id ,
					        'diagnosisName',dm.display_name ,
					        'specialityId',mi.speciality_mst_id ,
					        'specialityName',sm2."name" ,
					        'treatmentTypeId',mi.treatment_type_mst_id ,
					        'medicalAndChronicIllnessLink',v_json_ChronicIllness,
					        'submitted',false,
					        'treatmentTypeName',ttm."name" ,
					        'comments',mi.other_information 
		                ),
		                'insuranceInfo',json_build_object(
					        'id',ii.id ,
					        'claimInfoId',csl.claim_info_id ,
					        'claimStageId',csl.claim_stage_mst_id ,
					        'claimStageLinkId',csl.id ,
					        'isSubmitted',false,
					        'tpaIdCardNumber',ii.tpa_id_card_number ,
					        'policyHolderName',ii.policy_holder_name ,
					        'policyNumber',ii.policy_number ,
					        'isGroupPolicy',ii.is_group_policy ,
					        'groupCompany',ii.group_company ,
					        'groupCompanyEmpId',ii.group_company_emp_id ,
					        'claimIDPreAuthNumber',ii.claim_id_pre_auth_number ,
					        'approvedInitialAmount',ii.approval_amount_at_initial  ,
					        'approvedEnhancementsAmount',ii.approval_enhancement_amount ,
					        'approvedAmountAtDischarge',ii.approval_amount_at_discharge ,
					        'insuranceCompanyId',ii.insurance_company_mst_id ,
					        'insuranceCompanyName',icm."name" ,
					        'tpaId',ii.tpa_mst_id ,
					        'tpaName',tm."name" ,
					        'relationshipId',ii.relationship_mst_id ,
					        'relationshipName',rm."name" ,
					        'submitted',false,
		        			'groupPolicy',ii.is_group_policy ,
		        			'approvalAmountFinalStage' , ii.approval_amount_final_stage
		                ) 
		                 
		   			)    into v_main_response 
		 			from healspan.claim_stage_link csl 
					     LEFT JOIN healspan.patient_info pin ON pin.id = csl.patient_info_id
					     LEFT JOIN healspan.claim_info ci ON ci.id = csl.claim_info_id 
					     LEFT JOIN healspan.medical_info mi ON mi.id = csl.medical_info_id
					     LEFT JOIN healspan.insurance_info ii  ON ii.id = csl.insurance_info_id 
					     LEFT JOIN healspan.diagnosis_mst dm ON dm.id = mi.diagnosis_mst_id
					     LEFT JOIN healspan.claim_stage_mst csm ON csm.id = csl.claim_stage_mst_id
					     LEFT JOIN healspan.status_mst sm ON sm.id = csl.status_mst_id
					     LEFT JOIN healspan.hospital_mst hm ON hm.id = pin.hospital_mst_id
					     LEFT JOIN healspan.user_mst um ON um.id = csl.user_mst_id
					     LEFT JOIN healspan.user_role_mst urm ON urm.id = um.user_role_mst_id
					     left join healspan.room_category_mst rcm on rcm.id = pin.room_category_mst_id
					     left join healspan.gender_mst gm  on gm.id = pin.gender_mst_id 
					     left join healspan.treatment_type_mst ttm on ttm.id = mi.treatment_type_mst_id 
					     left join healspan.speciality_mst sm2 on sm2.id = mi.speciality_mst_id  
					     left join healspan.procedure_mst pm on pm.id = mi.procedure_mst_id
					     left join healspan.insurance_company_mst icm on icm.id = ii.insurance_company_mst_id 
					     left join healspan.tpa_mst tm on tm.id = ii.tpa_mst_id 
					     left join healspan.relationship_mst rm on rm.id = ii.relationship_mst_id 
					     where csl.id = v_claimstagelinkid;
	-------------------------------------------------------------------------------------------------
	-------------------append claim assignment ,doclist and questions json to --> claimInfo,patientInfo,medicalInfo,insuranceInfo detail json--------------------

	 select v_main_response || v_json_claimassignment || v_json_doclist || v_json_questions into v_json_response;
	-------------------------------------------------------------------------------------------------
	
	 return v_json_response;
	
	END;
$$;


ALTER FUNCTION healspan.get_claim_details(v_claimstagelinkid integer) OWNER TO root;

--
-- TOC entry 460 (class 1255 OID 111870)
-- Name: get_document_details(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_document_details(p_id integer) RETURNS TABLE(file_name character varying, file_path character varying, stage_link_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE 
    var_r record;
BEGIN
    FOR var_r IN(SELECT 
                "name", 
                "path",
                claim_stage_link_id
                FROM healspan."document" 
                where id = p_id)  
    LOOP
        file_name := var_r."name" ; 
        file_path := var_r."path";
        stage_link_id := var_r.claim_stage_link_id;
        RETURN NEXT;
    END LOOP;
END; $$;


ALTER FUNCTION healspan.get_document_details(p_id integer) OWNER TO root;

--
-- TOC entry 462 (class 1255 OID 50160)
-- Name: get_healspan_dashboard_details(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_healspan_dashboard_details(v_userid integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
   declare v_json_response jsonb;
   declare v_json_healspan jsonb;
   declare v_json_hospital jsonb;
   declare v_json_closed jsonb;
   
	begin
				   
		select json_build_object(
		        'reviewerClaimsDataList',json_agg(json_build_object(
                'claimID' , csl.claim_info_id ,
                'healspanClaimID' , ci.healspan_claim_id ,
                'claimStageLinkId', csl.id,
                'name', concat(pin.first_name, ' ', ltrim(concat(' ', COALESCE(pin.middle_name, ''::character varying), ' ', COALESCE(pin.last_name, ''::character varying)), ' '::text)),
                'ailment', dm.display_name,
                'stage', csm."name" ,
                'status', sm.name  ,
                'hospital', hm."name",
                'approvedAmount', pin.claimed_amount   ,
                'slaPercent',gcd.sla_percent,
                'ptat','-',
                'createdDateTime',csl.created_date_time, 
                'tpaClaimNumber',coalesce(ci.tpa_claim_number,'')
   								 )
   				--group by spcount."initialAuthorizationCount",spcount."enhancementCount",spcount."dischargeCount",spcount."finalClaimCount"
    ) 
    )into v_json_healspan 
    from  healspan.get_sla_details gcd
     LEFT JOIN healspan.claim_stage_link csl ON gcd.claim_id = csl.claim_info_id AND gcd.claim_stage_id = csl.claim_stage_mst_id
     inner join(select claim_info_id ,max(claim_stage_mst_id) as maxstage
					from healspan.claim_stage_link group by claim_info_id) topstage
					on topstage.claim_info_id = csl.claim_info_id and topstage.maxstage = csl.claim_stage_mst_id 
     LEFT JOIN healspan.patient_info pin ON pin.id = csl.patient_info_id
     LEFT JOIN healspan.claim_info ci ON ci.id = csl.claim_info_id 
     LEFT JOIN healspan.medical_info mi ON mi.id = csl.medical_info_id
     LEFT JOIN healspan.diagnosis_mst dm ON dm.id = mi.diagnosis_mst_id
     LEFT JOIN healspan.claim_stage_mst csm ON csm.id = csl.claim_stage_mst_id
     LEFT JOIN healspan.status_mst sm ON sm.id = csl.status_mst_id
     LEFT JOIN healspan.hospital_mst hm ON hm.id = pin.hospital_mst_id
    																																																																																																																																																																																																														 LEFT JOIN healspan.user_mst um ON um.id = csl.user_mst_id
     LEFT JOIN healspan.user_role_mst urm ON urm.id = um.user_role_mst_id
     where sm.name not in('Pending Documents','Approved','Rejected', 'Settled')
    --sm.name ='Pending Documents';
--     and um.user_role_mst_id = 2
     and gcd.user_mst_id = v_userid;
        
    
   select json_build_object(
		        'hospitalClaimsDataList',json_agg(json_build_object(
                'claimID' , csl.claim_info_id ,
                 'healspanClaimID' , ci.healspan_claim_id ,
                'claimStageLinkId', csl.id,
                'name', concat(pin.first_name, ' ', ltrim(concat(' ', COALESCE(pin.middle_name, ''::character varying), ' ', COALESCE(pin.last_name, ''::character varying)), ' '::text)),
                'ailment', dm.display_name,
                'stage', csm."name" ,
                'status', sm.name  ,
                'hospital', hm."name",
                'approvedAmount', pin.claimed_amount   ,
                'slaPercent',0,
                'ptat','-',
                'createdDateTime',csl.created_date_time, 
                'tpaClaimNumber',coalesce(ci.tpa_claim_number,'')
   								 )
   				--group by spcount."initialAuthorizationCount",spcount."enhancementCount",spcount."dischargeCount",spcount."finalClaimCount"
    )
    )into v_json_hospital 
    from healspan.claim_stage_link csl 
    inner join (select distinct claim_stage_link_id from healspan.claim_assignment ca where ca.user_mst_id = v_userid ) cidata on cidata.claim_stage_link_id = csl.id
    inner join(select claim_info_id ,max(claim_stage_mst_id) as maxstage
					from healspan.claim_stage_link group by claim_info_id) topstage
					on topstage.claim_info_id = csl.claim_info_id and topstage.maxstage = csl.claim_stage_mst_id  
    LEFT JOIN healspan.patient_info pin ON pin.id = csl.patient_info_id
     LEFT JOIN healspan.claim_info ci ON ci.id = csl.claim_info_id 
     LEFT JOIN healspan.medical_info mi ON mi.id = csl.medical_info_id
     LEFT JOIN healspan.diagnosis_mst dm ON dm.id = mi.diagnosis_mst_id
     LEFT JOIN healspan.claim_stage_mst csm ON csm.id = csl.claim_stage_mst_id
     LEFT JOIN healspan.status_mst sm ON sm.id = csl.status_mst_id
     LEFT JOIN healspan.hospital_mst hm ON hm.id = pin.hospital_mst_id
     LEFT JOIN healspan.user_mst um ON um.id = csl.user_mst_id
     LEFT JOIN healspan.user_role_mst urm ON urm.id = um.user_role_mst_id
     where sm.name in ('Pending Documents','Approved') ;
--     and um.user_role_mst_id = 2;
     --and csl.user_mst_id = v_userid;
   
		select json_build_object(
				        'closedClaimsDataList',json_agg(json_build_object(
		                'claimID' , csl.claim_info_id ,
		                'healspanClaimID' , ci.healspan_claim_id ,
		                'claimStageLinkId', csl.id,
		                'name', concat(pin.first_name, ' ', ltrim(concat(' ', COALESCE(pin.middle_name, ''::character varying), ' ', COALESCE(pin.last_name, ''::character varying)), ' '::text)),
		                'ailment', dm.display_name,
		                'stage', csm."name" ,
		                'status', sm.name  ,
		                'hospital', hm."name",
		                'approvedAmount', pin.claimed_amount   ,
		                'slaPercent',0,
		                'ptat','-',
		                'createdDateTime',csl.created_date_time, 
                		'tpaClaimNumber',coalesce(ci.tpa_claim_number,'')
		   								 )
		   				--group by spcount."initialAuthorizationCount",spcount."enhancementCount",spcount."dischargeCount",spcount."finalClaimCount"
		    )
		    )into v_json_closed 
		    from healspan.claim_stage_link csl 
		    inner join (select distinct claim_stage_link_id from healspan.claim_assignment ca where ca.user_mst_id = v_userid ) cidata on cidata.claim_stage_link_id = csl.id
		    inner join(select claim_info_id ,max(claim_stage_mst_id) as maxstage
					from healspan.claim_stage_link group by claim_info_id) topstage
					on topstage.claim_info_id = csl.claim_info_id and topstage.maxstage = csl.claim_stage_mst_id  
		    LEFT JOIN healspan.patient_info pin ON pin.id = csl.patient_info_id
		     LEFT JOIN healspan.claim_info ci ON ci.id = csl.claim_info_id 
		     LEFT JOIN healspan.medical_info mi ON mi.id = csl.medical_info_id
		     LEFT JOIN healspan.diagnosis_mst dm ON dm.id = mi.diagnosis_mst_id
		     LEFT JOIN healspan.claim_stage_mst csm ON csm.id = csl.claim_stage_mst_id
		     LEFT JOIN healspan.status_mst sm ON sm.id = csl.status_mst_id
		     LEFT JOIN healspan.hospital_mst hm ON hm.id = pin.hospital_mst_id
		     LEFT JOIN healspan.user_mst um ON um.id = csl.user_mst_id
		     LEFT JOIN healspan.user_role_mst urm ON urm.id = um.user_role_mst_id
		     where sm.name in('Settled','Rejected');
    
    select v_json_closed ||  v_json_hospital ||  v_json_healspan   into  v_json_response;
   
   return v_json_response;
		

	END;
$$;


ALTER FUNCTION healspan.get_healspan_dashboard_details(v_userid integer) OWNER TO root;

--
-- TOC entry 432 (class 1255 OID 50161)
-- Name: get_hospital_dashboard_details(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_hospital_dashboard_details(v_userid integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
   declare v_json_response jsonb;
   declare v_json_pending jsonb;
   declare v_json_approval jsonb;
   declare v_json_closed jsonb;
   declare v_piacount INT;
   declare v_pecount INT;
   declare v_pdcount INT;
   declare v_pfcount INT;
   declare v_aiacount INT;
   declare v_aecount INT;
   declare v_adcount INT;
   declare v_afcount INT;
  
   declare v_ciacount INT;
   declare v_cecount INT;
   declare v_cdcount INT;
   declare v_cfcount INT;
	begin
		
		
		create temp table if not exists temp_claimdetails (
					claimid int8,
					healspan_claim_id text,
					claimstagelinkid int8,
					patient_name text,
					ailment text,
					stage_name text,
					status text,
					admissiondate timestamp,
					dischargedate timestamp,
					aging int8,
					approvedamount int8,
					createddatetime timestamp,
					tpaclaimnumber text,
					last_updated_date_time timestamp,
					stageid int8,
					statusid int8
		) on commit drop;
		
	
		create temp table if not exists temp_pcount_json (
			p_iacount INT,
			p_ecount INT,
			p_dcount INT,
			p_fcount INT,
			a_iacount INT,
			a_ecount INT,
			a_dcount INT,
			a_fcount INT,
			c_iacount INT,
			c_ecount INT,
			c_dcount INT,
			c_fcount INT
			)on commit drop;
		
		
		  insert into temp_claimdetails
					select 
						csl.claim_info_id as claimid,
					    ci.healspan_claim_id ,
						csl.id as claimstagelinkid,
						concat(pin.first_name, ' ', ltrim(concat(' ', COALESCE(pin.middle_name, ''::character varying), ' ', COALESCE(pin.last_name, ''::character varying)), ' '::text)) as patient_name,
						dm.display_name as ailment,
						csm."name" as stage_name ,
						sm.name as status  ,
						pin.date_of_admission  as admissiondate ,
						pin.date_of_discharge as dischargedate  ,
						DATE_PART('day', CURRENT_TIMESTAMP - ci.created_date_time) as aging ,
						pin.claimed_amount as approvedamount,
						csl.created_date_time as createddatetime, 
						coalesce(ci.tpa_claim_number,'') as tpaclaimnumber,
						csl.last_updated_date_time,
						csl.claim_stage_mst_id,
						csl.status_mst_id
				 from healspan.claim_stage_link csl 
						inner join (select distinct claim_stage_link_id from healspan.claim_assignment ca where ca.user_mst_id = v_userid ) cidata on cidata.claim_stage_link_id = csl.id
						inner join(select claim_info_id ,max(claim_stage_mst_id) as maxstage
							from healspan.claim_stage_link group by claim_info_id) topstage
							on topstage.claim_info_id = csl.claim_info_id and topstage.maxstage = csl.claim_stage_mst_id  
						LEFT JOIN healspan.patient_info pin ON pin.id = csl.patient_info_id
						LEFT JOIN healspan.claim_info ci ON ci.id = csl.claim_info_id 
						LEFT JOIN healspan.medical_info mi ON mi.id = csl.medical_info_id
						LEFT JOIN healspan.diagnosis_mst dm ON dm.id = mi.diagnosis_mst_id
						LEFT JOIN healspan.claim_stage_mst csm ON csm.id = csl.claim_stage_mst_id
						LEFT JOIN healspan.status_mst sm ON sm.id = csl.status_mst_id
						LEFT JOIN healspan.hospital_mst hm ON hm.id = pin.hospital_mst_id
						LEFT JOIN healspan.user_mst um ON um.id = csl.user_mst_id
						LEFT JOIN healspan.user_role_mst urm ON urm.id = um.user_role_mst_id;
		
		   insert into temp_pcount_json
		       select  
				     COALESCE(sum ((CASE WHEN stageid =1 and status in ('Pending Documents', 'Approved')  THEN recordcount END)),0) AS p_iacount,
				     COALESCE(sum ((CASE WHEN stageid =2 and status in ('Pending Documents', 'Approved') THEN recordcount END)),0) AS p_ecount,
				     COALESCE(sum ((CASE WHEN stageid =3 and status in ('Pending Documents', 'Approved') THEN recordcount END)),0) AS p_dcount,
				     COALESCE(sum ((CASE WHEN stageid =4 and status in ('Pending Documents', 'Approved')  THEN recordcount END)),0) AS p_fcount,
				     COALESCE(sum ((CASE WHEN stageid =1 and status not in('Pending Documents','Approved','Settled','Rejected')  THEN recordcount END)),0) AS a_iacount,
				     COALESCE(sum ((CASE WHEN stageid =2 and status not in('Pending Documents','Approved','Settled','Rejected')  THEN recordcount END)),0) AS a_ecount,
				     COALESCE(sum ((CASE WHEN stageid =3 and status not in('Pending Documents','Approved','Settled','Rejected')  THEN recordcount END)),0) AS a_dcount,
				     COALESCE(sum ((CASE WHEN stageid =4 and status not in('Pending Documents','Approved','Settled','Rejected')  THEN recordcount END)),0) AS a_fcount,
					 COALESCE(sum ((CASE WHEN stageid =1 and status  in('Settled','Rejected')  THEN recordcount END)),0) AS c_iacount,
				     COALESCE(sum ((CASE WHEN stageid =2 and status  in('Settled','Rejected')  THEN recordcount END)),0) AS c_ecount,
				     COALESCE(sum ((CASE WHEN stageid =3 and status  in('Settled','Rejected')  THEN recordcount END)),0) AS c_dcount,
				     COALESCE(sum ((CASE WHEN stageid =4 and status  in('Settled','Rejected')  THEN recordcount END)),0) AS c_fcount
			    from (select stageid,status ,count(*) as recordcount from temp_claimdetails group by stageid,status) reccount;
			   
		select p_iacount,p_ecount,p_dcount,p_fcount,a_iacount,a_ecount,a_dcount,a_fcount,c_iacount,c_ecount,c_dcount,c_fcount 
		into v_piacount,v_pecount,v_pdcount,v_pfcount,v_aiacount,v_aecount,v_adcount,v_afcount,v_ciacount,v_cecount,v_cdcount,v_cfcount from temp_pcount_json;

	 with pending_dasbboard_json as (
    
     select json_build_object(
                'claimID' , claimid,
                'healspanClaimID' , healspan_claim_id,
                'claimStageLinkId', claimstagelinkid,
                'name', patient_name,
                'ailment', ailment,
                'stage', stage_name ,
                'status', status  ,
                'admissionDate', admissiondate  ,
                'dischargeDate', dischargedate   ,
                'aging',aging ,
                'approvedAmount',approvedamount,
                'createdDateTime',createddatetime, 
                'tpaClaimNumber',coalesce(tpaclaimnumber,'')
   								 ) as jsonstr
               
               from  temp_claimdetails where status in ('Pending Documents' , 'Approved')
			     order by createddatetime desc
    
        
    )
    
    select 
    json_build_object(
		      'claimStagePendingCount', json_build_object(
               'initialAuthorizationCount',v_piacount,
               'enhancementCount',v_pecount,
               'dischargeCount',v_pdcount,
               'finalClaimCount',v_pfcount,
               'pendingList',json_agg(jsonstr) )) into v_json_pending 
    from pending_dasbboard_json;
     
    
    
    with approval_dasbboard_json as (
    
     select json_build_object(
                'claimID' , claimid,
                'healspanClaimID' , healspan_claim_id,
                'claimStageLinkId', claimstagelinkid,
                'name', patient_name,
                'ailment', ailment,
                'stage', stage_name ,
                'status', status  ,
                'admissionDate', admissiondate  ,
                'dischargeDate', dischargedate   ,
                'aging',aging ,
                'approvedAmount',approvedamount,
                'createdDateTime',createddatetime, 
                'tpaClaimNumber',coalesce(tpaclaimnumber,'')
   								 ) as jsonstr
               
               from  temp_claimdetails where status not in('Pending Documents','Approved','Settled','Rejected') 
			     order by  COALESCE(last_updated_date_time,createddatetime) desc
    
        
    )
    
    select 
    json_build_object(
		      'claimStageApprovalCount', json_build_object(
               'initialAuthorizationCount',v_aiacount,
               'enhancementCount',v_aecount,
               'dischargeCount',v_adcount,
               'finalClaimCount',v_afcount,
               'approvalList',json_agg(jsonstr) )) into v_json_approval 
    from approval_dasbboard_json;
   
   
    with closed_dasbboard_json as (
    
     select json_build_object(
                'claimID' , claimid,
                'healspanClaimID' , healspan_claim_id,
                'claimStageLinkId', claimstagelinkid,
                'name', patient_name,
                'ailment', ailment,
                'stage', stage_name ,
                'status', status  ,
                'admissionDate', admissiondate  ,
                'dischargeDate', dischargedate   ,
                'aging',aging ,
                'approvedAmount',approvedamount,
                'createdDateTime',createddatetime, 
                'tpaClaimNumber',coalesce(tpaclaimnumber,'')
   								 ) as jsonstr
               
               from  temp_claimdetails where status in('Settled','Rejected')
			     order by  COALESCE(last_updated_date_time,createddatetime) desc
    
        
    )
    
    select 
    json_build_object(
		      'claimStageClosedCount', json_build_object(
               'initialAuthorizationCount',v_ciacount,
               'enhancementCount',v_cecount,
               'dischargeCount',v_cdcount,
               'finalClaimCount',v_cfcount,
               'closedList',json_agg(jsonstr) )) into v_json_closed 
    from closed_dasbboard_json;

--     and um.user_role_mst_id = 2;
     --and csl.user_mst_id = v_userid;
   

    
    select v_json_pending ||  v_json_approval || v_json_closed  into  v_json_response;
   
   return v_json_response;
		

	END;
$$;


ALTER FUNCTION healspan.get_hospital_dashboard_details(v_userid integer) OWNER TO root;

--
-- TOC entry 450 (class 1255 OID 69295)
-- Name: get_hospital_maxclaimid(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_hospital_maxclaimid(p_hospital_id integer) RETURNS character varying
    LANGUAGE plpgsql
    AS $$
   declare v_max_claim_id int;
  declare v_hospital_claimid varchar(100);
begin
-- select healspan.get_hospital_maxclaimid(2) 
select max_claim_id into v_max_claim_id 
from healspan.max_hospital_claim_id
where hospital_id = p_hospital_id;

if (select count(*) from healspan.max_hospital_claim_id where hospital_id = p_hospital_id) = 0 then
	v_max_claim_id := 1;
	
	insert into healspan.max_hospital_claim_id
	(hospital_id,max_claim_id)
	select p_hospital_id,v_max_claim_id;

else
	v_max_claim_id := v_max_claim_id + 1;
	
	update  healspan.max_hospital_claim_id
	set max_claim_id = v_max_claim_id
	where hospital_id = p_hospital_id;

end if;


select hm.hospital_code || '-' || replace(left(cast(now() as varchar),7),'-','') || '-' || cast(v_max_claim_id as varchar)
into v_hospital_claimid
from healspan.hospital_mst hm
where id = p_hospital_id;

return v_hospital_claimid;


END;
$$;


ALTER FUNCTION healspan.get_hospital_maxclaimid(p_hospital_id integer) OWNER TO root;

--
-- TOC entry 465 (class 1255 OID 51566)
-- Name: get_master_details(); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_master_details() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
    declare v_json_response jsonb;
    declare v_tpa_mst jsonb;
	declare v_other_costs_mst jsonb;
	declare v_diagnosis_mst jsonb;
	declare v_treatment_type_mst jsonb;
	declare v_status_mst jsonb;
	declare v_insurance_company_mst jsonb;
	declare v_procedure_mst jsonb;
	declare v_room_category_mst jsonb;
	declare v_mandatory_documents_mst jsonb;
	declare v_chronic_illness_mst jsonb;
	declare v_user_mst jsonb;
	declare v_gender_mst jsonb;
	declare v_claim_stage_mst jsonb;
	declare v_speciality_mst jsonb;
	declare v_relationship_mst jsonb;
	declare v_user_role_mst jsonb;
	declare v_hospital_mst jsonb;

	declare v_initial_stage jsonb;
	declare v_enhancement_stage jsonb;
	declare v_discharge_stage jsonb;
	declare v_final_stage jsonb;
  
	begin
		
		select json_build_object('tpa_mst',json_agg(json_build_object('id',id,'name',name,'code',code ))) into v_tpa_mst from healspan.tpa_mst where is_active ='Y';
		select json_build_object('hospital_mst',json_agg(json_build_object('id',id,'name',name,'hospitalCode',hospital_code,'about',about,'address',address,'boardLineNumber',board_line_num,'gstNum',gst_num,'hospitalId',hospital_id,'emailId',email_id ))) into v_hospital_mst from healspan.hospital_mst where is_active ='Y';
--		select json_build_object('other_costs_mst',json_agg(json_build_object('id',id,'name',name ))) into v_other_costs_mst from healspan.other_costs_mst where is_active ='Y';
--		select json_build_object('diagnosis_mst',json_agg(json_build_object('id',id,'ruleEngineName',rule_engine_name,'name',display_name,'tpaMstId',tpa_mst_id ))) into v_diagnosis_mst from healspan.diagnosis_mst where is_active ='Y';
--		select json_build_object('treatment_type_mst',json_agg(json_build_object('id',id,'name',name ))) into v_treatment_type_mst from healspan.treatment_type_mst where is_active ='Y';
--  	select json_build_object('discharge_stage',json_agg(json_build_object(id,name ))) into v_discharge_stage from healspan.discharge_stage where is_active ='Y';
--		select json_build_object('status_mst',json_agg(json_build_object('id',id,'name',name,'claimStageId',claim_stage_id ))) into v_status_mst from healspan.status_mst where is_active ='Y';
--		select json_build_object('insurance_company_mst',json_agg(json_build_object('id',id,'name',name ))) into v_insurance_company_mst from healspan.insurance_company_mst where is_active ='Y';
--  	select json_build_object('initial_stage',json_agg(json_build_object(id,name ))) into v_initial_stage from healspan.initial_stage where is_active ='Y';
--		select json_build_object('procedure_mst',json_agg(json_build_object('id',id,'name',display_name,'ruleEngineName',rule_engine_name,'tpaMstId',tpa_mst_id  ))) into v_procedure_mst from healspan.procedure_mst where is_active ='Y';
--		select json_build_object('room_category_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_room_category_mst from healspan.room_category_mst where is_active ='Y';
--  	select json_build_object('enhancement_stage',json_agg(json_build_object(id,name ))) into v_enhancement_stage from healspan.enhancement_stage where is_active ='Y';
--		select json_build_object('mandatory_documents_mst',json_agg(json_build_object('id',id,'name',name,'documentTypeId',document_type_mst_id ))) into v_mandatory_documents_mst from healspan.mandatory_documents_mst where is_active ='Y';
--   	select json_build_object('final_stage',json_agg(json_build_object(id,name ))) into v_final_stage from healspan.final_stage where is_active ='Y';
--		select json_build_object('chronic_illness_mst',json_agg(json_build_object('id',id,'name',name ))) into v_chronic_illness_mst from healspan.chronic_illness_mst where is_active ='Y';
--		select json_build_object('user_mst',json_agg(json_build_object('id',id,'firstName',first_name,'middleName', middle_name,'lastName', last_name,'userName', username,'email', email,'mobileNo', mobile_no,'active',is_active,'userRoleMstId',user_role_mst_id ))) into v_user_mst from healspan.user_mst where is_active ='Y';
--		select json_build_object('gender_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_gender_mst from healspan.gender_mst where is_active ='Y';
--		select json_build_object('claim_stage_mst',json_agg(json_build_object('id',id,'name',name ))) into v_claim_stage_mst from healspan.claim_stage_mst where is_active ='Y';
--		select json_build_object('speciality_mst',json_agg(json_build_object('id',id,'name',name))) into v_speciality_mst from healspan.speciality_mst where is_active ='Y';
--		select json_build_object('relationship_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_relationship_mst from healspan.relationship_mst where is_active ='Y';
--		select json_build_object('user_role_mst',json_agg(json_build_object('id',id,'name',name ))) into v_user_role_mst from healspan.user_role_mst where is_active ='Y';
--		select json_build_object('hospital_mst',json_agg(json_build_object('id',id,'name',name,'hospitalCode',hospital_code ))) into v_hospital_mst from healspan.hospital_mst where is_active ='Y';
--	
----	select json_build_object('mandatory_documents_mst',json_agg(json_build_object('id',id,'name',name,'documentTypeId',document_type_mst_id,'isActive',is_active  ))) into v_mandatory_documents_mst from healspan.mandatory_documents_mst where is_active ='Y';
--
--	
--	    select json_build_object('initial_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_initial_stage 
--		    from healspan.stage_and_document_link_mst sdl
--		    inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 1 ;
--	
--		select json_build_object('enhancement_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_enhancement_stage
--			from healspan.stage_and_document_link_mst sdl
--			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 2 ;
--		
--		select json_build_object('final_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_discharge_stage 
--			from healspan.stage_and_document_link_mst sdl
--			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 4 ;
--		
--		select json_build_object('discharge_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_final_stage 
--			from healspan.stage_and_document_link_mst sdl
--			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 3 ;

--	    select v_tpa_mst ||  v_other_costs_mst ||  v_diagnosis_mst ||  v_treatment_type_mst ||   v_status_mst ||  v_insurance_company_mst ||   v_procedure_mst ||  v_room_category_mst ||   v_mandatory_documents_mst ||  v_chronic_illness_mst ||   v_gender_mst ||  v_claim_stage_mst ||  v_speciality_mst ||  v_relationship_mst ||  v_hospital_mst ||  v_initial_stage ||  v_enhancement_stage ||  v_discharge_stage ||  v_final_stage into v_json_response; 

   		select v_tpa_mst || v_hospital_mst into v_json_response; 
   		
   return v_json_response;
		

	END;
$$;


ALTER FUNCTION healspan.get_master_details() OWNER TO root;

--
-- TOC entry 464 (class 1255 OID 138400)
-- Name: get_master_details(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_master_details(v_hospitalid integer) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
    declare v_json_response jsonb;
    declare v_tpa_mst jsonb;
	declare v_other_costs_mst jsonb;
	declare v_diagnosis_mst jsonb;
	declare v_treatment_type_mst jsonb;
	declare v_status_mst jsonb;
	declare v_insurance_company_mst jsonb;
	declare v_procedure_mst jsonb;
	declare v_room_category_mst jsonb;
	declare v_mandatory_documents_mst jsonb;
	declare v_chronic_illness_mst jsonb;
	declare v_user_mst jsonb;
	declare v_gender_mst jsonb;
	declare v_claim_stage_mst jsonb;
	declare v_speciality_mst jsonb;
	declare v_relationship_mst jsonb;
	declare v_user_role_mst jsonb;
	declare v_hospital_mst jsonb;

	declare v_initial_stage jsonb;
	declare v_enhancement_stage jsonb;
	declare v_discharge_stage jsonb;
	declare v_final_stage jsonb;
    declare v_contact_details jsonb;
  
	begin
		
		select json_build_object('tpa_mst',json_agg(json_build_object('id',id,'name',name,'code',code ))) into v_tpa_mst from healspan.tpa_mst where is_active ='Y';
	    select json_agg(json_build_object(
						'contact',contact ,
						'email',email,
						'firstname',firstname,
						'lastname',lastname,
						'designation',designation
						)) into v_contact_details 
						from healspan.contact_type where hospital_mst_id = v_hospitalid;
		select json_build_object('hospital_mst',json_build_object('id',id,'name',name,'hospitalCode',hospital_code,'about',about,'address',address,'boardLineNumber',board_line_num,'gstNum',gst_num,'hospitalId',hospital_id,'emailId',email_id,'contactDetails',v_contact_details )) into v_hospital_mst from healspan.hospital_mst where id = v_hospitalid and  is_active ='Y';
--		select json_build_object('other_costs_mst',json_agg(json_build_object('id',id,'name',name ))) into v_other_costs_mst from healspan.other_costs_mst where is_active ='Y';
--		select json_build_object('diagnosis_mst',json_agg(json_build_object('id',id,'ruleEngineName',rule_engine_name,'name',display_name,'tpaMstId',tpa_mst_id ))) into v_diagnosis_mst from healspan.diagnosis_mst where is_active ='Y';
--		select json_build_object('treatment_type_mst',json_agg(json_build_object('id',id,'name',name ))) into v_treatment_type_mst from healspan.treatment_type_mst where is_active ='Y';
--  	select json_build_object('discharge_stage',json_agg(json_build_object(id,name ))) into v_discharge_stage from healspan.discharge_stage where is_active ='Y';
--		select json_build_object('status_mst',json_agg(json_build_object('id',id,'name',name,'claimStageId',claim_stage_id ))) into v_status_mst from healspan.status_mst where is_active ='Y';
--		select json_build_object('insurance_company_mst',json_agg(json_build_object('id',id,'name',name ))) into v_insurance_company_mst from healspan.insurance_company_mst where is_active ='Y';
--  	select json_build_object('initial_stage',json_agg(json_build_object(id,name ))) into v_initial_stage from healspan.initial_stage where is_active ='Y';
--		select json_build_object('procedure_mst',json_agg(json_build_object('id',id,'name',display_name,'ruleEngineName',rule_engine_name,'tpaMstId',tpa_mst_id  ))) into v_procedure_mst from healspan.procedure_mst where is_active ='Y';
--		select json_build_object('room_category_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_room_category_mst from healspan.room_category_mst where is_active ='Y';
--  	select json_build_object('enhancement_stage',json_agg(json_build_object(id,name ))) into v_enhancement_stage from healspan.enhancement_stage where is_active ='Y';
--		select json_build_object('mandatory_documents_mst',json_agg(json_build_object('id',id,'name',name,'documentTypeId',document_type_mst_id ))) into v_mandatory_documents_mst from healspan.mandatory_documents_mst where is_active ='Y';
--   	select json_build_object('final_stage',json_agg(json_build_object(id,name ))) into v_final_stage from healspan.final_stage where is_active ='Y';
--		select json_build_object('chronic_illness_mst',json_agg(json_build_object('id',id,'name',name ))) into v_chronic_illness_mst from healspan.chronic_illness_mst where is_active ='Y';
--		select json_build_object('user_mst',json_agg(json_build_object('id',id,'firstName',first_name,'middleName', middle_name,'lastName', last_name,'userName', username,'email', email,'mobileNo', mobile_no,'active',is_active,'userRoleMstId',user_role_mst_id ))) into v_user_mst from healspan.user_mst where is_active ='Y';
--		select json_build_object('gender_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_gender_mst from healspan.gender_mst where is_active ='Y';
--		select json_build_object('claim_stage_mst',json_agg(json_build_object('id',id,'name',name ))) into v_claim_stage_mst from healspan.claim_stage_mst where is_active ='Y';
--		select json_build_object('speciality_mst',json_agg(json_build_object('id',id,'name',name))) into v_speciality_mst from healspan.speciality_mst where is_active ='Y';
--		select json_build_object('relationship_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_relationship_mst from healspan.relationship_mst where is_active ='Y';
--		select json_build_object('user_role_mst',json_agg(json_build_object('id',id,'name',name ))) into v_user_role_mst from healspan.user_role_mst where is_active ='Y';
--		select json_build_object('hospital_mst',json_agg(json_build_object('id',id,'name',name,'hospitalCode',hospital_code ))) into v_hospital_mst from healspan.hospital_mst where is_active ='Y';
--	
----	select json_build_object('mandatory_documents_mst',json_agg(json_build_object('id',id,'name',name,'documentTypeId',document_type_mst_id,'isActive',is_active  ))) into v_mandatory_documents_mst from healspan.mandatory_documents_mst where is_active ='Y';
--
--	
--	    select json_build_object('initial_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_initial_stage 
--		    from healspan.stage_and_document_link_mst sdl
--		    inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 1 ;
--	
--		select json_build_object('enhancement_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_enhancement_stage
--			from healspan.stage_and_document_link_mst sdl
--			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 2 ;
--		
--		select json_build_object('final_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_discharge_stage 
--			from healspan.stage_and_document_link_mst sdl
--			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 4 ;
--		
--		select json_build_object('discharge_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_final_stage 
--			from healspan.stage_and_document_link_mst sdl
--			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 3 ;

--	    select v_tpa_mst ||  v_other_costs_mst ||  v_diagnosis_mst ||  v_treatment_type_mst ||   v_status_mst ||  v_insurance_company_mst ||   v_procedure_mst ||  v_room_category_mst ||   v_mandatory_documents_mst ||  v_chronic_illness_mst ||   v_gender_mst ||  v_claim_stage_mst ||  v_speciality_mst ||  v_relationship_mst ||  v_hospital_mst ||  v_initial_stage ||  v_enhancement_stage ||  v_discharge_stage ||  v_final_stage into v_json_response; 

   		select v_tpa_mst || v_hospital_mst into v_json_response; 
   		
   return v_json_response;
		

	END;
$$;


ALTER FUNCTION healspan.get_master_details(v_hospitalid integer) OWNER TO root;

--
-- TOC entry 438 (class 1255 OID 50163)
-- Name: get_next_healspan_user(); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_next_healspan_user() RETURNS integer
    LANGUAGE plpgsql
    AS $$

declare v_userid INTEGER;
declare v_RECCONT INTEGER;
	begin
		
--		with NextHealspanUser as (
--				select distinct um.id as user_mst_id  from 
----				healspan.claim_assignment ca  LEFT JOIN 
--				  healspan.user_mst um --ON um.id = ca.user_mst_id
--				     LEFT JOIN healspan.user_role_mst urm ON urm.id = um.user_role_mst_id
--				     where um.user_role_mst_id = 3
--				     and um.id not in (
--				       select distinct user_mst_id from healspan.claim_assignment ca1
--				       LEFT JOIN healspan.user_mst um1 ON um1.id = ca1.user_mst_id
--				       LEFT JOIN healspan.user_role_mst urm1 ON urm1.id = um1.user_role_mst_id
--				       where ca1.completed_date_time is null
--				       and  um1.user_role_mst_id = 3
--				       )
--
--				
--				)
--		select user_mst_id into v_userid from NextHealspanUser  limit 1;
--	    if v_userid is null  then
--	        
--                  select min(um.id) into v_userid
--                          from healspan.user_mst um,healspan.user_role_mst urm
--                          where urm.id = um.user_role_mst_id
--                           and um.user_role_mst_id = 3;                  
--                                               
--           end if;
--          return v_userid;
		select id into v_userid from healspan.user_mst um where id > (
		select ca1.user_mst_id   from healspan.claim_assignment ca1
				       LEFT JOIN healspan.user_mst um1 ON um1.id = ca1.user_mst_id
				       LEFT JOIN healspan.user_role_mst urm1 ON urm1.id = um1.user_role_mst_id
				       LEFT JOIN healspan.status_mst sm ON sm.id = ca1.status_mst_id 
				       where  um1.user_role_mst_id = 3
				       and sm.name ='Pending HS Approval'
				       order by ca1.id desc limit 1
		
		)
		order by id limit 1 ;
	
	    if v_userid is null  then
	        
                  select min(um.id) into v_userid
                          from healspan.user_mst um,healspan.user_role_mst urm
                          where urm.id = um.user_role_mst_id
                           and um.user_role_mst_id = 3;                  
                                               
           end if;
          return v_userid;
	
			
				       
	END;
$$;


ALTER FUNCTION healspan.get_next_healspan_user() OWNER TO root;

--
-- TOC entry 452 (class 1255 OID 51567)
-- Name: get_next_hs_user(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_next_hs_user(v_claim_info_id integer) RETURNS integer
    LANGUAGE plpgsql
    AS $$
--select * from healspan.get_next_hs_user(7)
declare p_hs_user int;
declare p_current_hs_user int;
declare p_last_hs_user int;

BEGIN


p_current_hs_user := (
	select user_mst_id from healspan.claim_assignment ca , healspan.user_mst um 
	where claim_info_id = v_claim_info_id
	and ca.user_mst_id = um.id 
	and um.user_role_mst_id = 3
	limit 1
);

-------- get last assigned hs user_id
if 	p_current_hs_user is null then
	p_last_hs_user := (
		select ca.user_mst_id 
		from healspan.claim_assignment ca  , healspan.status_mst sm 
		where ca.status_mst_id = sm.id 
		and sm."name" = 'Pending HS Approval'
		and ca.user_mst_id is not null
		order by ca.claim_info_id desc
		limit 1
/*		    select user_mst_id from (
				select ROW_NUMBER () OVER (
				           PARTITION BY claim_info_id ,claim_stage_mst_id 
				           ORDER BY ID
				        ) as ROWNUM,id,claim_info_id ,claim_stage_mst_id ,user_mst_id
				 from healspan.claim_assignment 
				) A where ROWNUM = 2 order by ID desc limit 1 */
			);

	---- p_last_hs_user is null then set it to 0
	p_current_hs_user := COALESCE(p_current_hs_user, null,0);

	p_hs_user := (select min(id) from healspan.user_mst where user_role_mst_id =3
	and id > p_last_hs_user);
	
	IF  p_hs_user is null then
		p_hs_user := (select min(id) from healspan.user_mst where user_role_mst_id =3
		and id < p_last_hs_user);
	end if;
else
p_hs_user := p_current_hs_user;
end if;

 return p_hs_user;
	
END;
$$;


ALTER FUNCTION healspan.get_next_hs_user(v_claim_info_id integer) OWNER TO root;

--
-- TOC entry 430 (class 1255 OID 50164)
-- Name: get_sla_data(refcursor); Type: PROCEDURE; Schema: healspan; Owner: root
--

CREATE PROCEDURE healspan.get_sla_data(INOUT _result refcursor DEFAULT 'result'::refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
   

  open _result for 
			select csl.id as claim_stage_link_id,
				csl.claim_info_id,
				csl.claim_stage_mst_id as claim_stage_id,
				CONCAT  (pin.first_name , ' ',ltrim(concat(' ', COALESCE(pin.middle_name,''),' ',COALESCE(pin.last_name,'')),' ')) as Full_Name,
				csl.created_date_time,
				pin.date_of_discharge,
				dm.display_name as Ailment,
				csm.name as claim_Stage,
				sm.name as claim_status,
				pin.claimed_amount as Approved_Amount ,
				hm.name as hospital_name,
				gcd.user_mst_id 
				 from healspan.GET_CLA_DETAILS gcd
				 left join healspan.claim_stage_link csl on gcd.claim_id = csl.claim_info_id and gcd.claim_stage_id = csl.claim_stage_mst_id
				left join healspan.patient_info pin on pin.id = csl.patient_info_id 
				left join healspan.medical_info mi on mi.id =csl.medical_info_id 
				left join healspan.diagnosis_mst dm on dm.id = mi.diagnosis_mst_id 
				left join healspan.claim_stage_mst csm on csm.id =csl.claim_stage_mst_id 
				left join healspan.status_mst sm on sm.id = csl.status_mst_id 
				left join healspan.hospital_mst hm on hm.id = pin.hospital_mst_id
				order by 1 DESC;

 

END;
$$;


ALTER PROCEDURE healspan.get_sla_data(INOUT _result refcursor) OWNER TO root;

--
-- TOC entry 454 (class 1255 OID 102399)
-- Name: get_sla_exceeded_users(); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_sla_exceeded_users() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
begin
	

	select  jsonb_build_object (
'user_name',user_name,'email',email,'claimList',string_agg(claim_number,',') --as claimList
)   from
(
select  concat(um.first_name, ' ', COALESCE(um.last_name , ''::character varying)::text) as user_name,
um.email,ci.healspan_claim_id as claim_number 
--,gsd.sla_percent 
from healspan.get_sla_details gsd 
left join healspan.claim_info ci on ci.id = gsd.claim_id 
inner join healspan.user_mst um on um.id = gsd.user_mst_id 
where sla_percent > 75
)maildata group by user_name,email;
	END;
$$;


ALTER FUNCTION healspan.get_sla_exceeded_users() OWNER TO root;

--
-- TOC entry 463 (class 1255 OID 107125)
-- Name: get_tpawise_master_details(bigint); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_tpawise_master_details(v_tpamstid bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
   declare v_json_response jsonb;
   declare v_tpa_mst jsonb;
	declare v_other_costs_mst jsonb;
	declare v_diagnosis_mst jsonb;
	declare v_treatment_type_mst jsonb;
	
	declare v_status_mst jsonb;
	declare v_insurance_company_mst jsonb;
	
	declare v_procedure_mst jsonb;
	declare v_room_category_mst jsonb;
	
	declare v_mandatory_documents_mst jsonb;
	
	declare v_chronic_illness_mst jsonb;
	declare v_user_mst jsonb;
	declare v_gender_mst jsonb;
	declare v_claim_stage_mst jsonb;
	declare v_speciality_mst jsonb;
	declare v_relationship_mst jsonb;
	declare v_user_role_mst jsonb;
	declare v_hospital_mst jsonb;

	declare v_initial_stage jsonb;
	declare v_enhancement_stage jsonb;
	declare v_discharge_stage jsonb;
	declare v_final_stage jsonb;
  
	begin
		
	
--		select json_build_object('tpa_mst',json_agg(json_build_object('id',id,'name',name ))) into v_tpa_mst from healspan.tpa_mst where is_active ='Y';
		select json_build_object('other_costs_mst',json_agg(json_build_object('id',id,'name',name ))) into v_other_costs_mst from healspan.other_costs_mst where is_active ='Y';
		select json_build_object('diagnosis_mst',json_agg(json_build_object('id',id,'ruleEngineName',rule_engine_name,'name',display_name,'tpaMstId',tpa_mst_id ))) into v_diagnosis_mst from healspan.diagnosis_mst  where tpa_mst_id = v_tpaMstId and is_active ='Y';
		select json_build_object('treatment_type_mst',json_agg(json_build_object('id',id,'name',name ))) into v_treatment_type_mst from healspan.treatment_type_mst where is_active ='Y';
--		select json_build_object('discharge_stage',json_agg(json_build_object(id,name ))) into v_discharge_stage from healspan.discharge_stage where is_active ='Y';
		select json_build_object('status_mst',json_agg(json_build_object('id',id,'name',name,'claimStageId',claim_stage_id ))) into v_status_mst from healspan.status_mst where is_active ='Y';
		select json_build_object('insurance_company_mst',json_agg(json_build_object('id',id,'name',name ))) into v_insurance_company_mst from healspan.insurance_company_mst where is_active ='Y';
--		select json_build_object('initial_stage',json_agg(json_build_object(id,name ))) into v_initial_stage from healspan.initial_stage where is_active ='Y';
		select json_build_object('procedure_mst',json_agg(json_build_object('id',id,'name',display_name,'ruleEngineName',rule_engine_name,'tpaMstId',tpa_mst_id  ))) into v_procedure_mst from healspan.procedure_mst where tpa_mst_id = v_tpaMstId and  is_active ='Y';
		select json_build_object('room_category_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_room_category_mst from healspan.room_category_mst where tpa_mst_id = v_tpaMstId and  is_active ='Y';
--		select json_build_object('enhancement_stage',json_agg(json_build_object(id,name ))) into v_enhancement_stage from healspan.enhancement_stage where is_active ='Y';
		select json_build_object('mandatory_documents_mst',json_agg(json_build_object('id',id,'name',name,'documentTypeId',document_type_mst_id ))) into v_mandatory_documents_mst from healspan.mandatory_documents_mst where is_active ='Y';
--		select json_build_object('final_stage',json_agg(json_build_object(id,name ))) into v_final_stage from healspan.final_stage where is_active ='Y';
		select json_build_object('chronic_illness_mst',json_agg(json_build_object('id',id,'name',name ))) into v_chronic_illness_mst from healspan.chronic_illness_mst where is_active ='Y';
	--	select json_build_object('user_mst',json_agg(json_build_object('id',id,'firstName',first_name,'middleName', middle_name,'lastName', last_name,'userName', username,'email', email,'mobileNo', mobile_no,'active',is_active,'userRoleMstId',user_role_mst_id ))) into v_user_mst from healspan.user_mst where is_active ='Y';
		select json_build_object('gender_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_gender_mst from healspan.gender_mst where tpa_mst_id = v_tpaMstId and  is_active ='Y';
		select json_build_object('claim_stage_mst',json_agg(json_build_object('id',id,'name',name ))) into v_claim_stage_mst from healspan.claim_stage_mst where is_active ='Y';
		select json_build_object('speciality_mst',json_agg(json_build_object('id',id,'name',name))) into v_speciality_mst from healspan.speciality_mst where is_active ='Y';
		select json_build_object('relationship_mst',json_agg(json_build_object('id',id,'name',name,'tpaMstId',tpa_mst_id ))) into v_relationship_mst from healspan.relationship_mst where tpa_mst_id = v_tpaMstId and  is_active ='Y';
		--select json_build_object('user_role_mst',json_agg(json_build_object('id',id,'name',name ))) into v_user_role_mst from healspan.user_role_mst where is_active ='Y';
		select json_build_object('hospital_mst',json_agg(json_build_object('id',id,'name',name,'hospitalCode',hospital_code ))) into v_hospital_mst from healspan.hospital_mst where is_active ='Y';
	
--	    select json_build_object('mandatory_documents_mst',json_agg(json_build_object('id',id,'name',name,'documentTypeId',document_type_mst_id,'isActive',is_active  ))) into v_mandatory_documents_mst from healspan.mandatory_documents_mst where is_active ='Y';

	
	    select json_build_object('initial_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_initial_stage 
		from healspan.stage_and_document_link_mst sdl
		inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 1 ;
	
		select json_build_object('enhancement_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_enhancement_stage
			from healspan.stage_and_document_link_mst sdl
			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 2 ;
		
		select json_build_object('final_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_discharge_stage 
			from healspan.stage_and_document_link_mst sdl
			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 4 ;
		
		select json_build_object('discharge_stage',json_agg(json_build_object('id',mdm.id,'name',mdm.name,'documentTypeId',mdm.document_type_mst_id ))) into v_final_stage 
			from healspan.stage_and_document_link_mst sdl
			inner join healspan.mandatory_documents_mst mdm on mdm.id = sdl.mandatory_documents_mst_id  where sdl.claim_stage_mst_id = 3 ;

	    select   v_other_costs_mst ||  v_diagnosis_mst ||  v_treatment_type_mst ||   v_status_mst ||  v_insurance_company_mst ||   v_procedure_mst ||  v_room_category_mst ||   v_mandatory_documents_mst ||  v_chronic_illness_mst ||   v_gender_mst ||  v_claim_stage_mst ||  v_speciality_mst ||  v_relationship_mst ||    v_hospital_mst ||  v_initial_stage ||  v_enhancement_stage ||  v_discharge_stage ||  v_final_stage into v_json_response; 

   
   return v_json_response;
		

	END;
$$;


ALTER FUNCTION healspan.get_tpawise_master_details(v_tpamstid bigint) OWNER TO root;

--
-- TOC entry 466 (class 1255 OID 75078)
-- Name: get_user_notification(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.get_user_notification(p_user_mst_id integer) RETURNS text
    LANGUAGE plpgsql
    AS $$
-- select * from healspan.get_user_notification(7)

declare v_response_message text;
declare v_count int;

BEGIN

v_count := (select count(*) from
healspan.user_notification un 
where un.user_mst_id = p_user_mst_id and read_datetime is null);

  if (v_count > 0) then
  
	create temp table if not exists temp_notification (
			id INT,
			notification_text TEXT,
			claim_info_id INT,
			claim_stage_link_id INT,
			created_datetime timestamp
			)on commit drop;
		
  truncate table temp_notification;
		
			insert into temp_notification
			(id ,notification_text ,claim_info_id ,	claim_stage_link_id , created_datetime )
	        select  distinct un.id,
                 un.notification_text,
                 un.claim_info_id,
                 ca.claim_stage_link_id,
                 un.created_datetime
				from healspan.user_notification un , healspan.claim_assignment ca 
				where un.user_mst_id = p_user_mst_id and read_datetime is null
				and un.claim_info_id = ca.claim_info_id 
				and un.stage_master_id = ca.claim_stage_mst_id 
				and un.status_master_id = ca.status_mst_id 
				order by un.created_datetime desc ;    
    	
  with notification_json as (
    
     select json_build_object( 
                 'id', un.id,
                 'notificationText', un.notification_text,
                 'claimInfoId', un.claim_info_id,
                 'claimStageLinkId', un.claim_stage_link_id,
                 'createdDatetime', TO_CHAR(un.created_datetime , 'dd-Mon-yyyy hh12:mi:ss AM') 
   								 ) as jsonstr
               
				from temp_notification un
				order by un.created_datetime desc     
    )
       select json_agg(jsonstr) into v_response_message 
    from notification_json;
   
--       select json_agg(json_build_object(
--       'id', un.id,
--       'notificationText', un.notification_text,
--       'createdDatetime', un.created_datetime        	
--       )) into v_response_message
--       from healspan.user_notification un  
--       where un.user_mst_id = p_user_mst_id and read_datetime is null
       
--	  ;
  else
   	select json_build_object(
			       'id',null,
			       'notificationText', null,
			       'claimInfoId', null,
			       'claimStageLinkId', null,
			       'createdDatetime', null 		       
			      )into v_response_message;
			  
  end if;
 
 return v_response_message;
	
END;
$$;


ALTER FUNCTION healspan.get_user_notification(p_user_mst_id integer) OWNER TO root;

--
-- TOC entry 418 (class 1255 OID 112928)
-- Name: getdocumentdetails(integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.getdocumentdetails(p_id integer) RETURNS TABLE(file_name character varying, file_path character varying, stage_link_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE 
    var_r record;
BEGIN
    FOR var_r IN(SELECT 
                "name", 
                "path",
                claim_stage_link_id
                FROM healspan."document" 
                where id = p_id)  
    LOOP
        file_name := var_r."name" ; 
        file_path := var_r."path";
        stage_link_id := var_r.claim_stage_link_id;
        RETURN NEXT;
    END LOOP;
END; $$;


ALTER FUNCTION healspan.getdocumentdetails(p_id integer) OWNER TO root;

--
-- TOC entry 453 (class 1255 OID 85243)
-- Name: insert_app_error_log(integer, integer, text, text, text, text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.insert_app_error_log(p_claim_info_id integer, p_claim_assignment_id integer, p_function_name text, p_error_msg text, p_error_detail text, p_error_hint text) RETURNS void
    LANGUAGE plpgsql
    AS $$

begin
	
insert into healspan.app_error_log
(claim_info_id ,claim_assignment_id ,function_name ,error_msg ,
error_detail ,error_hint ,created_date)
select p_claim_info_id , p_claim_assignment_id , p_function_name , p_error_msg ,
p_error_detail ,p_error_hint, now();

END;
$$;


ALTER FUNCTION healspan.insert_app_error_log(p_claim_info_id integer, p_claim_assignment_id integer, p_function_name text, p_error_msg text, p_error_detail text, p_error_hint text) OWNER TO root;

--
-- TOC entry 431 (class 1255 OID 51555)
-- Name: insert_medical_info(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.insert_medical_info(jsondata text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
   declare v_medical_id int4;
	begin
		select nextval('healspan.medical_info_id_seq') into v_medical_id;

        insert into healspan.medical_info(id,approval_amount_at_discharge,approval_enhancement_amount,claim_id_pre_auth_number,group_company,initial_approval_limit,is_group_policy,policy_holder_name,policy_number,tpa_number,insurance_company_mst_id,relationship_mst_id,tpa_mst_id,group_company_emp_id)  
        select  v_medical_id,
                approval_amount_at_discharge,
				approval_enhancement_amount,
				claim_id_pre_auth_number,
				group_company,
				initial_approval_limit,
				is_group_policy,
				policy_holder_name,
				policy_number,
				tpa_number,
				insurance_company_mst_id,
				relationship_mst_id,
				tpa_mst_id,
				group_company_emp_id
				FROM jsonb_populate_record(NULL::healspan.medical_info,jsondata ::jsonb);
       
       return v_medical_id;
        
	END;
$$;


ALTER FUNCTION healspan.insert_medical_info(jsondata text) OWNER TO root;

--
-- TOC entry 447 (class 1255 OID 54666)
-- Name: insert_notification(integer, integer, integer, integer, integer); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.insert_notification(p_claim_info_id integer, p_claim_stage_mst_id integer, p_status_master_id integer, p_hospital_user_id integer, p_hs_user_id integer) RETURNS text
    LANGUAGE plpgsql
    AS $$
declare v_hs_user boolean;
declare v_hospital_user boolean;
declare v_notification text;
declare v_notification_config_id int;
declare v_response_message text;
declare v_healspan_claim_id text;
BEGIN

	
--select * from healspan.claim_assignment ca2 order by 1 desc	
	
--select * from healspan.insert_notification(17, 2,2,2,0)
select healspan_claim_id into v_healspan_claim_id from healspan.claim_info ci where id=p_claim_info_id;
	
--select * from healspan.claim_assignment ca where claim_info_id = 17;

--select * from healspan.user_notification where claim_info_id = 17	order by 1 desc	;
	
select nc.id , replace(nc.notification_text,'@claim_info_id', v_healspan_claim_id ) , nc.hospital_user , nc.hs_user  
into v_notification_config_id, v_notification, v_hospital_user, v_hs_user
from healspan.notification_config  nc
where status_master_id = p_status_master_id;

------- for hospital user
if v_hospital_user=true then
if p_hospital_user_id=0 then
	select ca.user_mst_id into p_hospital_user_id 
	from healspan.claim_assignment ca , healspan.user_mst um 
	where claim_info_id = p_claim_info_id
	and ca.user_mst_id =um.id 
	and um.user_role_mst_id =2
	order by ca.id desc
	limit 1;
end if;

	insert into healspan.user_notification 
	(notification_config_id, claim_info_id , stage_master_id , status_master_id , 
	notification_text, user_mst_id, created_datetime)
	select v_notification_config_id, p_claim_info_id, p_claim_stage_mst_id, p_status_master_id,
    v_notification, p_hospital_user_id, now();
end if;

------- for healspan user
if v_hs_user=true then
if p_hs_user_id=0 then
	select ca.user_mst_id into p_hs_user_id 
	from healspan.claim_assignment ca , healspan.user_mst um 
	where claim_info_id = p_claim_info_id
	and ca.user_mst_id =um.id 
	and um.user_role_mst_id =3
	order by ca.id desc
	limit 1;	
end if;

	insert into healspan.user_notification 
	(notification_config_id, claim_info_id , stage_master_id , status_master_id , 
	notification_text, user_mst_id, created_datetime)
	select v_notification_config_id, p_claim_info_id, p_claim_stage_mst_id, p_status_master_id,
    v_notification, p_hs_user_id, now();
end if;


return v_notification;
	
END;
$$;


ALTER FUNCTION healspan.insert_notification(p_claim_info_id integer, p_claim_stage_mst_id integer, p_status_master_id integer, p_hospital_user_id integer, p_hs_user_id integer) OWNER TO root;

--
-- TOC entry 439 (class 1255 OID 51556)
-- Name: insurance_info_iu(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.insurance_info_iu(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
   declare v_insurance_id int4;
   declare v_pk_id int4;
   declare v_claimstagelinkid int4;
   declare v_response_message text;
   declare v_tpaClaimNumber text;
   declare v_claim_info_id int;
	begin
		--select nextval('healspan.insurance_info_id_seq') into v_insurance_id;
		--drop TABLE IF EXISTS temp_insurance_info;
		
		create temp table if not exists temp_RESPONSE_json (
			"claimInfoId" INT,
			"patientInfoId" INT,
			"medicalInfoId" INT,
			"insuranceInfoId" INT,
			"claimStageLinkId" INT,
			"documentId" INT,
			"responseStatus" text,
			"tpaClaimNumber" text
			)on commit drop;
		
		create temp table if not exists temp_insurance_info (
             id  INT,
			"claimStageLinkId" double precision,
			"claimStageId" double precision,
			"tpaIdCardNumber" TEXT,
			"policyHolderName" TEXT,
			"policyNumber" TEXT,
			"isGroupPolicy" bool,
			"groupCompany" TEXT,
			"groupCompanyEmpId" TEXT,
			"claimIDPreAuthNumber" TEXT,
			"approvedInitialAmount" double precision,
			"approvedEnhancementsAmount" double precision,
			"approvedAmountAtDischarge" double precision,
			"tpaId" INT,
			"insuranceCompanyId" INT,
			"relationshipId" INT,
			"tpaClaimNumber" TEXT
      ) on commit drop;
    
      with insu as (
	    SELECT
			  x.* 
			from json_to_record( jsondata::json) AS x(
			id  INT,
			"claimStageLinkId" double precision,
			"claimStageId" double precision,
			"tpaIdCardNumber" TEXT,
			"policyHolderName" TEXT,
			"policyNumber" TEXT,
			"isGroupPolicy" bool,
			"groupCompany" TEXT,
			"groupCompanyEmpId" TEXT,
			"claimIDPreAuthNumber" TEXT,
			"approvedInitialAmount" double precision,
			"approvedEnhancementsAmount" double precision,
			"approvedAmountAtDischarge" double precision,
			"tpaId" INT,
			"insuranceCompanyId" INT,
			"relationshipId" INT,
			"tpaClaimNumber" TEXT
			)
		)
	
	 INSERT INTO temp_insurance_info (id  ,"claimStageLinkId" ,"claimStageId" ,"tpaIdCardNumber" ,"policyHolderName" ,"policyNumber" ,"isGroupPolicy" ,"groupCompany" ,"groupCompanyEmpId" ,"claimIDPreAuthNumber" ,"approvedInitialAmount" ,"approvedEnhancementsAmount" ,"approvedAmountAtDischarge" ,"tpaId","insuranceCompanyId" ,"relationshipId", "tpaClaimNumber" ) 
	                       select     id  ,"claimStageLinkId" ,"claimStageId" ,"tpaIdCardNumber" ,"policyHolderName" ,"policyNumber" ,"isGroupPolicy" ,"groupCompany" ,"groupCompanyEmpId" ,"claimIDPreAuthNumber" ,"approvedInitialAmount" ,"approvedEnhancementsAmount" ,"approvedAmountAtDischarge" ,"tpaId","insuranceCompanyId" ,"relationshipId", "tpaClaimNumber" from insu;
       
	   select id into v_insurance_id from temp_insurance_info limit 1;
	   select "claimStageLinkId" into v_claimstagelinkid from temp_insurance_info limit 1;	  
	   select "tpaClaimNumber" into v_tpaClaimNumber from temp_insurance_info limit 1;
	   select claim_info_id  into v_claim_info_id from healspan.claim_stage_link csl where id=v_claimstagelinkid;
	 
	   if v_insurance_id is null then
	    	     
	 	 insert into healspan.insurance_info(approval_amount_at_discharge,approval_enhancement_amount,claim_id_pre_auth_number,group_company,approval_amount_at_initial,is_group_policy,policy_holder_name,policy_number,tpa_id_card_number,insurance_company_mst_id,relationship_mst_id,tpa_mst_id,group_company_emp_id)
            select   -- v_insurance_id,
                "approvedAmountAtDischarge",
				"approvedEnhancementsAmount",
				"claimIDPreAuthNumber",
				"groupCompany",
				"approvedInitialAmount",
				"isGroupPolicy",
				"policyHolderName",
				"policyNumber",
				"tpaIdCardNumber",
				"insuranceCompanyId",
				"relationshipId",
				"tpaId",
				"groupCompanyEmpId"
				from temp_insurance_info;
			
			select currval('healspan.insurance_info_id_seq') into v_insurance_id;
			
			update healspan.claim_stage_link set insurance_info_id = v_insurance_id where id = v_claimstagelinkid;
		
			update healspan.claim_info set tpa_claim_number = v_tpaClaimNumber where id= v_claim_info_id;
			
	  else
	  
				Update healspan.insurance_info p
				set claim_id_pre_auth_number = temp_update."claimIDPreAuthNumber",
					group_company = temp_update."groupCompany",					
					is_group_policy = temp_update."isGroupPolicy",
					policy_holder_name = temp_update."policyHolderName",
					policy_number = temp_update."policyNumber",
					tpa_id_card_number = temp_update."tpaIdCardNumber",
					insurance_company_mst_id = temp_update."insuranceCompanyId",
					relationship_mst_id = temp_update."relationshipId",
					tpa_mst_id = temp_update."tpaId",
					group_company_emp_id = temp_update."groupCompanyEmpId"
				from temp_insurance_info temp_update
				where temp_update.id =p.id 
				and p.id = v_insurance_id;
			
				update healspan.claim_info set tpa_claim_number = v_tpaClaimNumber where id= v_claim_info_id;
			
	  END IF;
	   
	 insert into temp_RESPONSE_json 
	 values(null,null,null,v_insurance_id,v_claimstagelinkid ,null,'SUCCESS') ;
	
	 SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
				   
			
	 return v_response_message;
			
        
	END;
$$;


ALTER FUNCTION healspan.insurance_info_iu(jsondata text) OWNER TO root;

--
-- TOC entry 451 (class 1255 OID 51557)
-- Name: medical_info_iu(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.medical_info_iu(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
   declare v_medical_id int4;
   declare v_claimstagelinkid int4;
   declare v_response_message text;
	begin
		--select nextval('healspan.insurance_info_id_seq') into v_medical_id;
		--drop TABLE IF EXISTS temp_medical_info;
		
		create temp table if not exists temp_RESPONSE_json (
			"claimInfoId" INT,
			"patientInfoId" INT,
			"medicalInfoId" INT,
			"insuranceInfoId" INT,
			"claimStageLinkId" INT,
			"documentId" INT,
			"responseStatus" TEXT
			)on commit drop;
		
		create temp table if not exists temp_medical_info (
				"id" INT,
				"claimStageLinkId" double precision,
				"dateOfFirstDiagnosis" TIMESTAMP,
				"claimStageId" INT,
				"doctorName" TEXT,
				"doctorRegistrationNumber" TEXT,
				"doctorQualification" TEXT,
				"diagnosisId" INT,
				"procedureId" INT,
				"specialityId" INT,
				"treatmentTypeId" INT,
				 "comments" text,
				"medicalAndChronicIllnessLink" json
      ) on commit drop;
    
      with medi as (
	    SELECT
			  x.* 
			from json_to_record( jsondata::json) AS x(
				"id" INT,
				"claimStageLinkId" double precision,
				"dateOfFirstDiagnosis" TIMESTAMP,
				"claimStageId" INT,
				"doctorName" TEXT,
				"doctorRegistrationNumber" TEXT,
				"doctorQualification" TEXT,
				"diagnosisId" INT,
				"procedureId" INT,
				"specialityId" INT,
				"treatmentTypeId" INT,
				"comments" text,
				"medicalAndChronicIllnessLink" json
			)
		)
	
	 INSERT INTO temp_medical_info ("id","claimStageLinkId","dateOfFirstDiagnosis","claimStageId","doctorName","doctorRegistrationNumber","doctorQualification","diagnosisId","procedureId","specialityId","treatmentTypeId","medicalAndChronicIllnessLink" ,"comments") 
	                       select   "id","claimStageLinkId","dateOfFirstDiagnosis","claimStageId","doctorName","doctorRegistrationNumber","doctorQualification","diagnosisId","procedureId","specialityId","treatmentTypeId","medicalAndChronicIllnessLink","comments" from medi;
       
	   select id into v_medical_id from temp_medical_info limit 1;
	   select "claimStageLinkId" into v_claimstagelinkid from temp_medical_info limit 1;
	    
	   if v_medical_id is null then
	    
	     
	 	 insert into healspan.medical_info (date_of_first_diagnosis,doctor_name,doctor_qualification,doctor_registration_number,diagnosis_mst_id,procedure_mst_id,speciality_mst_id,treatment_type_mst_id,other_information)
            select    
					"dateOfFirstDiagnosis",
					"doctorName",
					"doctorQualification",
					"doctorRegistrationNumber",
					"diagnosisId",
					"procedureId",
					"specialityId",
					"treatmentTypeId",
					"comments" 
				from temp_medical_info;
			
	     select currval('healspan.medical_info_id_seq') into v_medical_id;
			
		 update healspan.claim_stage_link set medical_info_id  = v_medical_id where id = v_claimstagelinkid;
			
	  else
	  
				Update healspan.medical_info p
				set date_of_first_diagnosis = temp."dateOfFirstDiagnosis",
					doctor_name = temp."doctorName",
					doctor_qualification = temp."doctorQualification",
					doctor_registration_number = temp."doctorRegistrationNumber",
					diagnosis_mst_id = temp."diagnosisId",
					procedure_mst_id = temp."procedureId",
					speciality_mst_id = temp."specialityId",
					treatment_type_mst_id = temp."treatmentTypeId",
					other_information = temp."comments"	
				from temp_medical_info temp
				where temp.id =p.id 
				and p.id = v_medical_id;
			
			
			
	  END IF;
	 
	 delete from healspan.medical_chronic_illness_link where medical_info_id = v_medical_id;
			
	 insert into healspan.medical_chronic_illness_link(chronic_illness_mst_id,medical_info_id)
	 select x.id ,v_medical_id from temp_medical_info,json_to_recordset(temp_medical_info."medicalAndChronicIllnessLink"::json) AS x(id INT);
	 
	
	 insert into temp_RESPONSE_json 
	 values(null,null,v_medical_id,null,v_claimstagelinkid ,null,'SUCCESS') ;
	
	 SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
				   
			
	 return v_response_message;
			
	 
			
      
        
	END;
$$;


ALTER FUNCTION healspan.medical_info_iu(jsondata text) OWNER TO root;

--
-- TOC entry 435 (class 1255 OID 51558)
-- Name: patient_info_iu(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.patient_info_iu(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
   declare v_patient_id int4;
   declare v_hospitalid int4;
   declare v_userid int4;
   declare v_claimstageid int4;
   declare v_statusid int4;
   declare v_claimstagelinkid int4;
   declare v_claimid int4;
   declare v_response_message text;
   declare v_healspan_claim_id text;   
  
  begin
		drop TABLE IF EXISTS temp_patient_json;
		
		create temp table if not exists temp_RESPONSE_json (
			"claimInfoId" INT,
			"patientInfoId" INT,
			"healspanClaimNo" text,
			"medicalInfoId" INT,
			"insuranceInfoId" INT,
			"claimStageLinkId" INT,
			"documentId" INT,
			"responseStatus" TEXT
			);
			
		create temp table if not exists temp_patient_json (key TEXT,value TEXT);
		
		insert into temp_patient_json
		select key,value  from json_each( jsondata::json);
		
	    select (case when value='null' then NULL else value::integer end) into v_claimid from temp_patient_json where key = 'id' limit 1;
		select (case when value='null' then NULL else value::integer end) into v_claimstagelinkid from temp_patient_json where key = 'claimStageLinkId' limit 1;
		select (case when value='null' then NULL else value::integer end) into v_userid from temp_patient_json where key = 'userId' limit 1;
		select (case when value='null' then NULL else value::integer end) into v_hospitalid from temp_patient_json where key = 'hospitalId' limit 1;
		select (case when value='null' then NULL else value::integer end) into v_claimstageid from temp_patient_json where key = 'claimStageId' limit 1;
--		select value into v_statusid from temp_patient_json where key = 'statusId' limit 1;
		
       ----------insert/update into patient_info logic-------------------------------------------------
	     drop TABLE IF EXISTS temp_patientDTO;
	     create temp table if not exists temp_patientDTO (
				 id INT,
				"firstName" TEXT,
				"middleName" TEXT,
				"lastname" TEXT,
				"mobileNo" TEXT,
				"dateBirth" TIMESTAMP,
				"age" INT,
				"isPrimaryInsured" bool,
				"dateOfAdmission" TIMESTAMP,
				"estimatedDateOfDischarge" TIMESTAMP,
				"dateOfDischarge" TIMESTAMP,
				"costPerDay" double precision,
				"totalRoomCost" double precision,
				"otherCostsEstimate" double precision,
				"initialCostEstimate" double precision,
				"billNumber" TEXT,
				"claimedAmount" double precision,
				"enhancementEstimate" double precision,
				"finalBillAmount" double precision,
				"patientUhid" TEXT,
				"hospitalId" INT,
				"roomCategoryId" INT,
				"genderId" INT,
				"patientAndOtherCostLink" TEXT[]
		);
	
	  with pationtdata as (
		    SELECT
				  x.* 
				from temp_patient_json,json_to_record(temp_patient_json.value::json) AS x(
				 id INT,
				"firstName" TEXT,
				"middleName" TEXT,
				"lastname" TEXT,
				"mobileNo" TEXT,
				"dateBirth" TIMESTAMP,
				"age" INT,
				"isPrimaryInsured" bool,
				"dateOfAdmission" TIMESTAMP,
				"estimatedDateOfDischarge" TIMESTAMP,
				"dateOfDischarge" TIMESTAMP,
				"costPerDay" double precision,
				"totalRoomCost" double precision,
				"otherCostsEstimate" double precision,
				"initialCostEstimate" double precision,
				"billNumber" TEXT,
				"claimedAmount" double precision,
				"enhancementEstimate" double precision,
				"finalBillAmount" double precision,
				"patientUhid" TEXT,
				"hospitalId" INT,
				"roomCategoryId" INT,
				"genderId" INT,
				"patientAndOtherCostLink" TEXT[]
				)
				where key ='patientInfoDto'
			)
		
		insert into temp_patientDTO
		select * from pationtdata;
       
	    select id into v_patient_id from temp_patientDTO limit 1;
	  
	    if v_patient_id is null then
	   
--			   select nextval('healspan.patient_info_id_seq') into v_patient_id;
		       select min(id) into v_statusid from healspan.status_mst  where claim_stage_id  = v_claimstageid;
		        insert into healspan.patient_info(age,bill_number,claimed_amount,cost_per_day,date_of_birth,date_of_admission,date_of_discharge,enhancement_estimation,estimated_date_of_discharge,final_bill_amount,first_name,patient_uhid,initial_costs_estimation,is_primary_insured,last_name,middle_name,mobile_no,other_costs_estimation,total_room_cost,gender_mst_id,hospital_mst_id,room_category_mst_id)  
		        select  -- v_patient_id,
						"age",
						"billNumber",
						"claimedAmount",
						"costPerDay",
						"dateBirth",
						"dateOfAdmission",
						"dateOfDischarge",
						"enhancementEstimate",
						"estimatedDateOfDischarge",
						"finalBillAmount",
						"firstName",
						"patientUhid",
						"initialCostEstimate",
						"isPrimaryInsured",
						"lastname",
						"middleName",
						"mobileNo",
						"otherCostsEstimate",
						"totalRoomCost",
						"genderId",
						"hospitalId",
						"roomCategoryId"
						FROM temp_patientDTO;
					
					select currval('healspan.patient_info_id_seq') into v_patient_id;
					
					select healspan.get_hospital_maxclaimid(v_hospitalid) into v_healspan_claim_id;
					
					insert into healspan.claim_info(created_date_time,hospital_mst_id,user_mst_id, healspan_claim_id)
				                         values(current_timestamp,v_hospitalid,v_userid,v_healspan_claim_id);
				                        
				    select currval('healspan.claim_info_id_seq') into v_claimid;
				    
				    
				    insert into healspan.claim_stage_link (created_date_time,claim_info_id,claim_stage_mst_id,patient_info_id,status_mst_id,user_mst_id)
						 values(current_timestamp,v_claimid,v_claimstageid,v_patient_id,v_statusid, v_userid);
						
					select currval('healspan.claim_stage_link_id_seq') into v_claimstagelinkid;
						
					insert into healspan.claim_assignment (assigned_date_time,claim_info_id,claim_stage_link_id,claim_stage_mst_id,status_mst_id,user_mst_id)
					                                values(current_timestamp,v_claimid,v_claimstagelinkid,v_claimstageid,v_statusid, v_userid);
					                               
					insert into temp_RESPONSE_json 
					values(v_claimid,v_patient_id,v_healspan_claim_id,null,null,v_claimstagelinkid,null,'SUCCESS') ;
					
				    SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
				   
--				    return v_response_message;
						
		   else
		   
					   Update healspan.patient_info p
						set  age = temp_update."age",
							 bill_number = temp_update."billNumber",
							 claimed_amount = temp_update."claimedAmount",
							 cost_per_day = temp_update."costPerDay",
							 date_of_birth = temp_update."dateBirth",
							 date_of_admission = temp_update."dateOfAdmission",
							 date_of_discharge = temp_update."dateOfDischarge",
							 enhancement_estimation = temp_update."enhancementEstimate",
							 estimated_date_of_discharge = temp_update."estimatedDateOfDischarge",
							 final_bill_amount = temp_update."finalBillAmount",
							 first_name = temp_update."firstName",
							 patient_uhid = temp_update."patientUhid",
							 initial_costs_estimation = temp_update."initialCostEstimate",
							 is_primary_insured = temp_update."isPrimaryInsured",
							 last_name = temp_update."lastname",
							 middle_name = temp_update."middleName",
							 mobile_no = temp_update."mobileNo",
							 other_costs_estimation = temp_update."otherCostsEstimate",
							 total_room_cost = temp_update."totalRoomCost",
							 gender_mst_id = temp_update."genderId",
							 hospital_mst_id = temp_update."hospitalId",
							 room_category_mst_id = temp_update."roomCategoryId"
					from temp_patientDTO temp_update
					where temp_update.id =p.id 
					and p.id = v_patient_id;
				
				  select healspan_claim_id into v_healspan_claim_id from healspan.claim_info ci where ci.id = v_claimid;
				   insert into temp_RESPONSE_json 
					values(v_claimid,v_patient_id,v_healspan_claim_id,null,null,v_claimstagelinkid,null,'SUCCESS') ;
					
				    SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
				   
				   
	       END IF; 
	        ----------Finish-insert/update into patient_info logic-------------------------------------------------
	       -------insert details of patient_othercost_link table----------------------------------
			 create temp table if not exists temp_patient_othercost (
							"other_costs_mst_id" INT,
							amount double precision
							) on commit drop;
			insert into temp_patient_othercost
			select x.id,x.amount from (
			select * from 
			(
			SELECT patientdata.key,patientdata.value FROM  temp_patient_json,  json_each_text(temp_patient_json.value::json) as patientdata 
					where  temp_patient_json.key ='patientInfoDto'
			) linkdata
			where linkdata.key ='patientAndOtherCostLink'
			) linkdata,json_to_recordset(linkdata.value::json) AS x(id INT, amount double precision);
			
			
			delete from healspan.patient_othercost_link where patient_info_id = v_patient_id;
			
			insert into healspan.patient_othercost_link(amount,other_costs_mst_id,patient_info_id)
			select amount,other_costs_mst_id,v_patient_id from temp_patient_othercost;	
		 -------Finish-insert details of patient_othercost_link table----------------------------------
	   
	  return v_response_message;	
			
      
        
	END;
$$;


ALTER FUNCTION healspan.patient_info_iu(jsondata text) OWNER TO root;

--
-- TOC entry 448 (class 1255 OID 53388)
-- Name: query_claim(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.query_claim(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
--select * from healspan.get_next_hs_user(585)

declare p_current_hs_user int;
declare p_assignto_user_id int; 
declare p_next_status_master_id int;
declare p1_claim_stage_link_id int;
declare p_maxid int;
declare v_claim_info_id integer;
declare v_claim_stage_mst_id integer;
declare v_flowtype text;
declare v_claim_stage_link_id integer;
 declare v_response_message text;
declare v_transfer_comment text;
declare  v_nresponse text;

BEGIN

	create temp table if not exists temp_RESPONSE_json (
			"claimId" INT,
			"claimStageLinkId" INT,
			"responseStatus" TEXT
			)on commit drop;

create temp table if not exists temp_comments_json (key TEXT,value TEXT);
insert into temp_comments_json
select key,value  from json_each( jsondata::json);

select (case when value='null' then NULL else value::integer end) into v_claim_info_id from temp_comments_json where key = 'claimId' limit 1;
select (case when value='null' then NULL else value::integer end) into v_claim_stage_mst_id from temp_comments_json where key = 'stageId' limit 1;
select (case when value='null' then NULL else value::text end) into v_flowtype from temp_comments_json where key = 'flowType' limit 1;
select (case when value='null' then NULL else value::text end) into v_transfer_comment from temp_comments_json where key = 'transferComment' limit 1;

select id into v_claim_stage_link_id from healspan.claim_stage_link csl 
where claim_info_id = v_claim_info_id and claim_stage_mst_id = v_claim_stage_mst_id;
--------------update query doc ids in document table-----------------------
create temp table if not exists temp_current_documents(
		mandatory_documents_mst_id int
		)on commit drop;
	
insert into temp_current_documents
SELECT x.value::integer 
	    FROM  temp_comments_json,  json_array_elements_text(temp_comments_json.value::json) AS x 
		where  temp_comments_json.key ='documentIds';
	

	delete from healspan."document" where claim_stage_link_id = v_claim_stage_link_id
	and mandatory_documents_mst_id in (select mandatory_documents_mst_id from temp_current_documents);
	
    INSERT INTO healspan."document"(claim_stage_link_id, mandatory_documents_mst_id, status)
	SELECT v_claim_stage_link_id,mandatory_documents_mst_id,false from temp_current_documents;
	     
-----------------------------------------------------
	
------ submit claim
create temp table if not exists temp_current_assigment(
		p_claim_assigment_id int,
		p_claim_stage_link_id int,
		p_status_master_id int
		)on commit drop;


insert into temp_current_assigment
(p_claim_assigment_id,p_claim_stage_link_id,p_status_master_id)
select ca.id, ca.claim_stage_link_id, ca.status_mst_id  
from healspan.claim_assignment ca 
where claim_info_id = v_claim_info_id
and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

---- update current assignment compleated date
update healspan.claim_assignment 
set completed_date_time = now()
where claim_info_id = v_claim_info_id
and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

------ get next status master id
p_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Pending Documents' 
			);
		
----- get Hospital user for assignment
	
p_assignto_user_id := (
		select user_mst_id from healspan.claim_assignment ca , healspan.user_mst um 
		where claim_info_id = v_claim_info_id
		and user_mst_id = um.id 
		and um.user_role_mst_id =2
		order by ca.assigned_date_time desc 
		limit 1
);


p1_claim_stage_link_id := (select p_claim_stage_link_id  from temp_current_assigment);
--p_maxid := (select max(id) + 1 from healspan.claim_assignment);

INSERT INTO healspan.claim_assignment
( assigned_date_time, assigned_comments, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
claim_stage_mst_id, user_mst_id, status_mst_id)
select  now(), replace(v_transfer_comment,'"',''), 2, v_claim_info_id, tmp.p_claim_stage_link_id , 
v_claim_stage_mst_id, p_assignto_user_id, p_next_status_master_id 
from temp_current_assigment tmp;

----------- update stage link

update healspan.claim_stage_link 
set status_mst_id = p_next_status_master_id, user_mst_id = p_assignto_user_id
where id  = p1_claim_stage_link_id;
----------------------------------------------

select * from healspan.insert_notification(v_claim_info_id, v_claim_stage_mst_id,p_next_status_master_id,p_assignto_user_id,0) into v_nresponse;


insert into temp_RESPONSE_json values (v_claim_info_id,v_claim_stage_link_id,'SUCCESS');

SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
return v_response_message;

	
END;
$$;


ALTER FUNCTION healspan.query_claim(jsondata text) OWNER TO root;

--
-- TOC entry 434 (class 1255 OID 51560)
-- Name: question_doc_iu(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.question_doc_iu(jsondata text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
   declare v_claimstagelinkid int8;
   declare v_response_message jsonb;
   declare v_json_doclist jsonb;
  declare v_claim_info_id int8;
	begin
		--drop TABLE IF EXISTS temp_questionsAndDocs_json;
		
--		create temp table if not exists temp_RESPONSE_json (
--			"claimInfoId" INT,
--			"patientInfoId" INT,
--			"medicalInfoId" INT,
--			"insuranceInfoId" INT,
--			"claimStageLinkId" INT,
--			"documentId" json,
--			"responseStatus" TEXT
--			);
			
		create temp table if not exists temp_questionsAndDocs_json (key TEXT,value TEXT) on commit drop;
		
		insert into temp_questionsAndDocs_json
		select key,value  from json_each( jsondata::json);
		
	    
		select value into v_claimstagelinkid from temp_questionsAndDocs_json where key = 'claimStageLinkId' limit 1;
		
	    select claim_info_id into v_claim_info_id from healspan.claim_stage_link where id = v_claimstagelinkid limit 1;
	   
		INSERT INTO healspan.question_answer(answers, questions, claim_stage_link_id)
		SELECT x.question,x.answer,v_claimstagelinkid
		FROM  temp_questionsAndDocs_json,  json_to_recordset(temp_questionsAndDocs_json.value::json) AS x(question text, answer text) 
		where  temp_questionsAndDocs_json.key ='sequentialQuestion';

	    INSERT INTO healspan."document"(claim_stage_link_id, mandatory_documents_mst_id, status)
	    SELECT v_claimstagelinkid,x.value::integer,false 
	    FROM  temp_questionsAndDocs_json,  json_array_elements_text(temp_questionsAndDocs_json.value::json) AS x 
		where  temp_questionsAndDocs_json.key ='documentIdList';
	
	   select  json_build_object('documentList',json_agg(json_build_object(
							'id',d.id ,
							'documentsMstId',d.mandatory_documents_mst_id ,
							'mandatoryDocumentName',mdm."name",
							'documentName',d."name" ,
							'documentPath',d."path",
							'status',d.status,
							'claimStageMstId',csl.claim_stage_mst_id
		                ))) into v_json_doclist 
			from healspan."document" d 
			inner join healspan.mandatory_documents_mst mdm on mdm.id = d.mandatory_documents_mst_id 
			left join healspan.claim_stage_link csl on csl.id = d.claim_stage_link_id 
		    where csl.claim_info_id = v_claim_info_id ;
			--where d.claim_stage_link_id = v_claimstagelinkid;
		
	
	  select jsonb_build_object(
				  'claimInfoId', null,
				  'patientInfoId', null,
				  'medicalInfoId', null,
				  'insuranceInfoId', null,
				  'claimStageLinkId', null,
--				  'documentId',json_agg( json_build_object(
--				   mandatory_documents_mst_id,id))
--				  ,
				  'responseStatus', 'SUCCESS'
				) into v_response_message 
				from healspan."document" d 
			where claim_stage_link_id = v_claimstagelinkid;

	   
	  return v_response_message || v_json_doclist ;	
			
      
        
	END;
$$;


ALTER FUNCTION healspan.question_doc_iu(jsondata text) OWNER TO root;

--
-- TOC entry 449 (class 1255 OID 53186)
-- Name: submit_claim(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.submit_claim(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
--select * from healspan.submit_claim(605,1,'submit', 'dummy')
--select * from healspan.get_next_hs_user(585)
--{
--    "claimId": 608,
--    "stageId": 4,
--    "flowType": "HOSPITAL_USER_SUBMITTED_CLAIM",
--    "transferComment": null
--}
declare p_current_hs_user int;
declare p_last_hs_user int;
declare p_assignto_user_id int; 
declare p_next_status_master_id int;
declare p1_claim_stage_link_id int;
declare p_maxid int;
declare v_claim_info_id integer;
declare v_claim_stage_mst_id integer;
declare v_flowtype text;
declare v_transfercomment text;
declare v_response_message text;
declare v_nresponse text;
BEGIN

	create temp table if not exists temp_RESPONSE_json (
			"claimId" INT,
			"claimStageLinkId" INT,
			"responseStatus" TEXT
			)on commit drop;
	
	select x."claimId" ,x."stageId",x."flowType",x."transferComment" into v_claim_info_id,v_claim_stage_mst_id,v_flowtype,v_transfercomment  
			from json_to_record( jsondata::json) AS x(
				
				"claimId" INT,
				"stageId" INT,
				"flowType" text,
				"transferComment" text
			);
------ submit claim
create temp table if not exists temp_current_assigment(
		p_claim_assigment_id int,
		p_claim_stage_link_id int,
		p_status_master_id int
		)on commit drop;


insert into temp_current_assigment
(p_claim_assigment_id,p_claim_stage_link_id, p_status_master_id)
select ca.id, ca.claim_stage_link_id, ca.status_mst_id  
from healspan.claim_assignment ca 
where claim_info_id = v_claim_info_id
--and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

---- update current assignment compleated date
update healspan.claim_assignment 
set completed_date_time = now()
where claim_info_id = v_claim_info_id
and claim_stage_mst_id = v_claim_stage_mst_id
and completed_date_time is null;

------ get next status master id
p_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Pending HS Approval' 
			);
		
----- get HS user for assignment
p_assignto_user_id  := (select * from healspan.get_next_hs_user(v_claim_info_id));

if p_assignto_user_id is null then
     p_assignto_user_id  := (select min(id) from healspan.user_mst um where user_role_mst_id = 3 limit 1);
end if;

p1_claim_stage_link_id := (select p_claim_stage_link_id  from temp_current_assigment);
--p_maxid := (select max(id) + 1 from healspan.claim_assignment);

INSERT INTO healspan.claim_assignment
( assigned_date_time, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
claim_stage_mst_id, user_mst_id, status_mst_id)
select  now(), 3, v_claim_info_id, tmp.p_claim_stage_link_id , 
v_claim_stage_mst_id, p_assignto_user_id , p_next_status_master_id 
from temp_current_assigment tmp;

----------- update stage link
update healspan.claim_stage_link 
set status_mst_id = p_next_status_master_id, user_mst_id = p_assignto_user_id
where id  = p1_claim_stage_link_id;

select * from healspan.insert_notification(v_claim_info_id, v_claim_stage_mst_id,p_next_status_master_id,0,p_assignto_user_id) into v_nresponse;

--return p_assignto_user_id ;
insert into temp_RESPONSE_json values (v_claim_info_id,0,'SUCCESS');

SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
return v_response_message;
	
END;
$$;


ALTER FUNCTION healspan.submit_claim(jsondata text) OWNER TO root;

--
-- TOC entry 455 (class 1255 OID 59122)
-- Name: submit_tpa_action(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.submit_tpa_action(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
--{
--  "claimId" : 559,
--  "stageId" : 1,
--  "claimNumber" : "559KK",
--  "transferComment" : "Test 559-1",
--  "status"  : "APPROVED"
--}

declare v_next_status_master_id int;
declare v_claim_stage_link_id int;
declare v_claim_info_id integer;
declare v_claim_stage_mst_id integer;
declare v_claimNumber text;
declare v_transfercomment text;
declare v_response_message text;
declare v_status text;
declare v_hospital_user_id int;
declare v_hs_user_id int;
declare v_assignto_user_id int;
declare v_approved_amount numeric;
declare v_settled_amount numeric;

declare v_nresponse text;
declare error_msg text;
declare error_detail text;
declare error_hint text;

BEGIN

	select x."claimId" ,x."stageId",x."claimNumber",x."transferComment", 
	x."status" , x."approvedAmount" , x."settledAmount"
	into v_claim_info_id, v_claim_stage_mst_id,v_claimNumber,v_transfercomment, 
	v_status, v_approved_amount, v_settled_amount
			from json_to_record( jsondata::json) AS x(
				
				"claimId" INT,
				"stageId" INT,
				"claimNumber" text,
				"transferComment" text,
				"status" text,
				"approvedAmount" numeric,
				"settledAmount" numeric
			);
		
----------- Update 	tpa claim number if not updated
	update healspan.claim_info ci 
	set tpa_claim_number = v_claimNumber
	where id = v_claim_info_id
	and tpa_claim_number is null;		

---------- get current assignment stage link id
	select ca.claim_stage_link_id  into 
	v_claim_stage_link_id   --, v_claim_stage_mst_id 
	from healspan.claim_assignment ca 
	where claim_info_id = v_claim_info_id
	and completed_date_time is null;
	
-------- update current assignment compleated date
	update healspan.claim_assignment 
	set completed_date_time = now()
	where claim_info_id = v_claim_info_id
	and claim_stage_mst_id = v_claim_stage_mst_id
	and completed_date_time is null;

-------- Get hospital user id
	select ca.user_mst_id into v_hospital_user_id 
	from healspan.claim_assignment ca , healspan.user_mst um 
	where claim_info_id = v_claim_info_id
	and ca.user_mst_id =um.id 
	and um.user_role_mst_id =2
	order by ca.id desc
	limit 1;

--------- get Healspan user id
	select ca.user_mst_id into v_hs_user_id 
	from healspan.claim_assignment ca , healspan.user_mst um 
	where claim_info_id = v_claim_info_id
	and ca.user_mst_id =um.id 
	and um.user_role_mst_id =3
	order by ca.id desc
	limit 1;

--------- Approve
	if 	upper(v_status) = upper('approved') Then

	v_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Approved' 
			);

	INSERT INTO healspan.claim_assignment
	( assigned_date_time, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
	claim_stage_mst_id, user_mst_id, status_mst_id)
	select  now(), 2, v_claim_info_id, v_claim_stage_link_id , 
	v_claim_stage_mst_id, v_hospital_user_id , v_next_status_master_id;
	
    v_assignto_user_id := v_hospital_user_id;
	
   end if;
-------- Query
	if 	upper(v_status) = upper('QUERY') Then

	v_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'TPA Query' 
			);

	INSERT INTO healspan.claim_assignment
	( assigned_date_time, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
	claim_stage_mst_id, user_mst_id, status_mst_id)
	select  now(), 3, v_claim_info_id, v_claim_stage_link_id , 
	v_claim_stage_mst_id, v_hs_user_id , v_next_status_master_id;
	
	v_assignto_user_id := v_hs_user_id;
	end if;

-------- Settled
	if 	upper(v_status) = upper('settled') Then

	v_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Settled' 
			);

	INSERT INTO healspan.claim_assignment
	( assigned_date_time, completed_date_time, assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
	claim_stage_mst_id, user_mst_id, status_mst_id)
	select  now(), now(), 2, v_claim_info_id, v_claim_stage_link_id , 
	v_claim_stage_mst_id, v_hospital_user_id , v_next_status_master_id;
	
	v_assignto_user_id := v_hospital_user_id;
	end if;

-------- Reject
	if 	upper(v_status) = upper('rejected') Then

	v_next_status_master_id := (
			select id from healspan.status_mst sm 
			where sm.claim_stage_id = v_claim_stage_mst_id
			and sm."name"  = 'Rejected' 
			);

	INSERT INTO healspan.claim_assignment
	( assigned_date_time, completed_date_time , assigned_to_user_role_mst_id, claim_info_id, claim_stage_link_id, 
	claim_stage_mst_id, user_mst_id, status_mst_id)
	select  now(), now(), 2, v_claim_info_id, v_claim_stage_link_id , 
	v_claim_stage_mst_id, v_hospital_user_id , v_next_status_master_id;
	
	v_assignto_user_id := v_hospital_user_id;
	end if;

----------- update previous claim stage link id status

	update healspan.claim_stage_link 
	set status_mst_id = v_next_status_master_id,
	user_mst_id = v_assignto_user_id
	where id = v_claim_stage_link_id;
		
   ------------- send notification
    select * from healspan.insert_notification(v_claim_info_id, v_claim_stage_mst_id,v_next_status_master_id,0,0) into v_nresponse;

	create temp table if not exists temp_RESPONSE_json (
			"claimId" INT,
			"claimStageLinkId" INT,
			"responseStatus" text,
			"errorMessage" text,
			"errorDetail" text,
			"errorHint" text
	)on commit drop;
	
--select * from healspan.tpa_update tu 
-------- insert into healspan.tpa_update 
INSERT INTO healspan.tpa_update
(approved_amount, settled_amount, remarks, status, tpa_claim_number, claim_stage_id, 
status_mst_id, claim_stage_link_id, claim_info_id, created_datetime)
VALUES(v_approved_amount, v_settled_amount, v_transfercomment , v_status, v_claimNumber , v_claim_stage_mst_id,
v_next_status_master_id, v_claim_stage_link_id, v_claim_info_id, now()  
);

----------- update approved amount 
if v_claim_stage_mst_id = 1 then
	update healspan.insurance_info
	set approval_amount_at_initial = v_approved_amount
	from  healspan.claim_stage_link csl 
	where csl.insurance_info_id = healspan.insurance_info.id 
	and csl.id = v_claim_stage_link_id and csl.claim_info_id = v_claim_info_id;
elseif v_claim_stage_mst_id = 2 then
	update healspan.insurance_info
	set approval_enhancement_amount = v_approved_amount
	from  healspan.claim_stage_link csl 
	where csl.insurance_info_id = healspan.insurance_info.id 
	and csl.id = v_claim_stage_link_id and csl.claim_info_id = v_claim_info_id;
elseif  v_claim_stage_mst_id = 3 then
	update healspan.insurance_info
	set approval_amount_at_discharge = v_approved_amount
	from  healspan.claim_stage_link csl 
	where csl.insurance_info_id = healspan.insurance_info.id 
	and csl.id = v_claim_stage_link_id and csl.claim_info_id = v_claim_info_id;
end if;
---------- update final settled amount
if v_settled_amount > 0 then
	update healspan.insurance_info
	set approval_amount_final_stage = v_settled_amount
	from  healspan.claim_stage_link csl 
	where csl.insurance_info_id = healspan.insurance_info.id 
	and csl.id = v_claim_stage_link_id and csl.claim_info_id = v_claim_info_id;
end if;

--return p_assignto_user_id ;
	insert into temp_RESPONSE_json values (v_claim_info_id,0,'SUCCESS',null,null,null);
	
	SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
	
	/*EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS text_var1 = MESSAGE_TEXT,
                          text_var2 = PG_EXCEPTION_DETAIL,
                          text_var3 = PG_EXCEPTION_HINT;   
*/
	return v_response_message;
    EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_msg := MESSAGE_TEXT,
                          error_detail := PG_EXCEPTION_DETAIL,
                          error_hint := PG_EXCEPTION_HINT;
	insert into temp_RESPONSE_json values (v_claim_info_id,0,'FAIL',error_msg,error_detail,error_hint);	
	SELECT cast (row_to_json(temp_RESPONSE_json) as text) into v_response_message FROM temp_RESPONSE_json limit 1;
	return v_response_message;

END;
$$;


ALTER FUNCTION healspan.submit_tpa_action(jsondata text) OWNER TO root;

--
-- TOC entry 459 (class 1255 OID 111869)
-- Name: update_document_details(integer, text, text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.update_document_details(p_id integer, p_filename text, p_filepath text) RETURNS text
    LANGUAGE plpgsql
    AS $$
declare v_response_message text;
	begin
--	  select * from healspan."document";
	 update healspan."document" set "name" = p_filename ,"path" = p_filepath,status=true  where id = p_id;
     
	select jsonb_build_object(
	  'responseStatus','SUCCESS'
    ) into v_response_message  ;
   
    return v_response_message;
	END;
$$;


ALTER FUNCTION healspan.update_document_details(p_id integer, p_filename text, p_filepath text) OWNER TO root;

--
-- TOC entry 436 (class 1255 OID 77998)
-- Name: update_user_notification(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.update_user_notification(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$
-- select * from healspan.update_user_notification(7)

declare v_response_message text;
declare v_id  INT8;
declare v_userid int8;
declare v_clearall text;
BEGIN

	select x.id,x."userId",x."clearAll" into v_id,v_userid,v_clearall 
		from json_to_record( jsondata::json) AS x( id int,"userId" INT ,"clearAll" TEXT);
					
	 if (v_clearall = 'NO') then
	 
	    update healspan.user_notification 
		set read_datetime = now()
		where id = v_id;

	 else 
	 
	    update healspan.user_notification 
		set read_datetime = now()
		where user_mst_id = v_userid;
	   
	 end if;


		select json_build_object(
		       	'responseStatus','SUCCESS'
			       )into v_response_message;
 

 return v_response_message;
	
END;
$$;


ALTER FUNCTION healspan.update_user_notification(jsondata text) OWNER TO root;

--
-- TOC entry 433 (class 1255 OID 52757)
-- Name: updatedocumentdetails(integer, text, text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.updatedocumentdetails(p_id integer, p_filename text, p_filepath text) RETURNS text
    LANGUAGE plpgsql
    AS $$
declare v_response_message text;
	begin
--	  select * from healspan."document";
	 update healspan."document" set "name" = p_filename ,"path" = p_filepath,status=true  where id = p_id;
     
	select jsonb_build_object(
	  'responseStatus','SUCCESS'
    ) into v_response_message  ;
   
    return v_response_message;
	END;
$$;


ALTER FUNCTION healspan.updatedocumentdetails(p_id integer, p_filename text, p_filepath text) OWNER TO root;

--
-- TOC entry 443 (class 1255 OID 55578)
-- Name: validate_user(text); Type: FUNCTION; Schema: healspan; Owner: root
--

CREATE FUNCTION healspan.validate_user(jsondata text) RETURNS text
    LANGUAGE plpgsql
    AS $$

declare v_response_message text;
declare v_count integer;
declare v_username text;
declare v_password text;

BEGIN


select x.username ,x.password  into v_username,v_password from json_to_record( jsondata::json) AS x(username text,
				password text
			);

v_count := (select count(*)  from healspan.user_mst um where upper(username)=upper(v_username) and password = v_password);

  if (v_count > 0) then
       select json_build_object(
       'id',um.id,
       'userName',username,
       'firstName',first_name ,
       	'lastName',last_name ,
       	'hospitalMstId',hospital_mst_id ,
       	'hospitalName',hm."name"  ,
       	'userRoleMstId',user_role_mst_id ,
       	'email',email ,
       	'mobileNo',mobile_no,
       	'responseStatus','SUCCESS'
       ) into v_response_message
       from healspan.user_mst um 
       left join healspan.hospital_mst hm on hm.id = um.hospital_mst_id 
       where upper(username)=upper(v_username) and password = v_password;
  else
  
  		select json_build_object(
			       'id',null,
			       'userName',null,
			       'firstName',null ,
			       	'lastName',null ,
			       	'hospitalMstId',null ,
			       	'userRoleMstId',null ,
			       	'email',null ,
			       	'mobileNo',null,
			       	'responseStatus','FAIL'
			       )into v_response_message;
  
  end if;
 
 return v_response_message;
	
END;
$$;


ALTER FUNCTION healspan.validate_user(jsondata text) OWNER TO root;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 404 (class 1259 OID 85211)
-- Name: app_error_log; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.app_error_log (
    id integer NOT NULL,
    claim_info_id integer,
    claim_assignment_id integer,
    function_name text,
    error_msg text,
    error_detail text,
    error_hint text,
    created_date timestamp without time zone
);


ALTER TABLE healspan.app_error_log OWNER TO root;

--
-- TOC entry 403 (class 1259 OID 85210)
-- Name: app_error_log_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.app_error_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.app_error_log_id_seq OWNER TO root;

--
-- TOC entry 4897 (class 0 OID 0)
-- Dependencies: 403
-- Name: app_error_log_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.app_error_log_id_seq OWNED BY healspan.app_error_log.id;


--
-- TOC entry 338 (class 1259 OID 49309)
-- Name: chronic_illness_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.chronic_illness_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.chronic_illness_mst OWNER TO root;

--
-- TOC entry 337 (class 1259 OID 49308)
-- Name: chronic_illness_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.chronic_illness_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.chronic_illness_mst_id_seq OWNER TO root;

--
-- TOC entry 4898 (class 0 OID 0)
-- Dependencies: 337
-- Name: chronic_illness_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.chronic_illness_mst_id_seq OWNED BY healspan.chronic_illness_mst.id;


--
-- TOC entry 340 (class 1259 OID 49316)
-- Name: claim_assignment; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.claim_assignment (
    id bigint NOT NULL,
    action_taken character varying(255),
    assigned_date_time timestamp without time zone,
    assigned_comments character varying(255),
    completed_date_time timestamp without time zone,
    assigned_to_user_role_mst_id bigint,
    claim_info_id bigint,
    claim_stage_link_id bigint,
    claim_stage_mst_id bigint,
    status_mst_id bigint,
    user_mst_id bigint,
    iteration_instance bigint
);


ALTER TABLE healspan.claim_assignment OWNER TO root;

--
-- TOC entry 339 (class 1259 OID 49315)
-- Name: claim_assignment_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.claim_assignment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.claim_assignment_id_seq OWNER TO root;

--
-- TOC entry 4899 (class 0 OID 0)
-- Dependencies: 339
-- Name: claim_assignment_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.claim_assignment_id_seq OWNED BY healspan.claim_assignment.id;


--
-- TOC entry 342 (class 1259 OID 49325)
-- Name: claim_info; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.claim_info (
    id bigint NOT NULL,
    created_date_time timestamp without time zone,
    tpa_claim_number character varying(255),
    hospital_mst_id bigint,
    user_mst_id bigint,
    healspan_claim_id character varying(100)
);


ALTER TABLE healspan.claim_info OWNER TO root;

--
-- TOC entry 341 (class 1259 OID 49324)
-- Name: claim_info_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.claim_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.claim_info_id_seq OWNER TO root;

--
-- TOC entry 4900 (class 0 OID 0)
-- Dependencies: 341
-- Name: claim_info_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.claim_info_id_seq OWNED BY healspan.claim_info.id;


--
-- TOC entry 344 (class 1259 OID 49332)
-- Name: claim_stage_link; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.claim_stage_link (
    id bigint NOT NULL,
    created_date_time timestamp without time zone,
    last_updated_date_time timestamp without time zone,
    claim_info_id bigint,
    claim_stage_mst_id bigint,
    insurance_info_id bigint,
    medical_info_id bigint,
    patient_info_id bigint,
    status_mst_id bigint,
    user_mst_id bigint
);


ALTER TABLE healspan.claim_stage_link OWNER TO root;

--
-- TOC entry 343 (class 1259 OID 49331)
-- Name: claim_stage_link_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.claim_stage_link_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.claim_stage_link_id_seq OWNER TO root;

--
-- TOC entry 4901 (class 0 OID 0)
-- Dependencies: 343
-- Name: claim_stage_link_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.claim_stage_link_id_seq OWNED BY healspan.claim_stage_link.id;


--
-- TOC entry 346 (class 1259 OID 49339)
-- Name: claim_stage_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.claim_stage_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying,
    sla_time integer
);


ALTER TABLE healspan.claim_stage_mst OWNER TO root;

--
-- TOC entry 345 (class 1259 OID 49338)
-- Name: claim_stage_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.claim_stage_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.claim_stage_mst_id_seq OWNER TO root;

--
-- TOC entry 4902 (class 0 OID 0)
-- Dependencies: 345
-- Name: claim_stage_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.claim_stage_mst_id_seq OWNED BY healspan.claim_stage_mst.id;


--
-- TOC entry 398 (class 1259 OID 66374)
-- Name: contact_type; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.contact_type (
    id bigint NOT NULL,
    contact character varying(255),
    email character varying(255),
    firstname character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying,
    lastname character varying(255),
    hospital_mst_id bigint,
    designation character varying(255)
);


ALTER TABLE healspan.contact_type OWNER TO root;

--
-- TOC entry 397 (class 1259 OID 66373)
-- Name: contact_type_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.contact_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.contact_type_id_seq OWNER TO root;

--
-- TOC entry 4903 (class 0 OID 0)
-- Dependencies: 397
-- Name: contact_type_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.contact_type_id_seq OWNED BY healspan.contact_type.id;


--
-- TOC entry 348 (class 1259 OID 49346)
-- Name: diagnosis_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.diagnosis_mst (
    id bigint NOT NULL,
    display_name character varying(255),
    rule_engine_name character varying(255),
    tpa_mst_id bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.diagnosis_mst OWNER TO root;

--
-- TOC entry 347 (class 1259 OID 49345)
-- Name: diagnosis_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.diagnosis_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.diagnosis_mst_id_seq OWNER TO root;

--
-- TOC entry 4904 (class 0 OID 0)
-- Dependencies: 347
-- Name: diagnosis_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.diagnosis_mst_id_seq OWNED BY healspan.diagnosis_mst.id;


--
-- TOC entry 350 (class 1259 OID 49355)
-- Name: document; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.document (
    id bigint NOT NULL,
    name character varying(255),
    path character varying(255),
    status boolean,
    claim_stage_link_id bigint,
    mandatory_documents_mst_id bigint,
    is_deleted character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.document OWNER TO root;

--
-- TOC entry 349 (class 1259 OID 49354)
-- Name: document_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.document_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.document_id_seq OWNER TO root;

--
-- TOC entry 4905 (class 0 OID 0)
-- Dependencies: 349
-- Name: document_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.document_id_seq OWNED BY healspan.document.id;


--
-- TOC entry 352 (class 1259 OID 49364)
-- Name: document_type_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.document_type_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.document_type_mst OWNER TO root;

--
-- TOC entry 351 (class 1259 OID 49363)
-- Name: document_type_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.document_type_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.document_type_mst_id_seq OWNER TO root;

--
-- TOC entry 4906 (class 0 OID 0)
-- Dependencies: 351
-- Name: document_type_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.document_type_mst_id_seq OWNED BY healspan.document_type_mst.id;


--
-- TOC entry 409 (class 1259 OID 107073)
-- Name: gender_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.gender_mst (
    id bigint NOT NULL,
    name character varying(255),
    tpa_mst_id bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.gender_mst OWNER TO root;

--
-- TOC entry 408 (class 1259 OID 107072)
-- Name: gender_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.gender_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.gender_mst_id_seq OWNER TO root;

--
-- TOC entry 4907 (class 0 OID 0)
-- Dependencies: 408
-- Name: gender_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.gender_mst_id_seq OWNED BY healspan.gender_mst.id;


--
-- TOC entry 388 (class 1259 OID 49532)
-- Name: user_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.user_mst (
    id bigint NOT NULL,
    email character varying(255),
    first_name character varying(255),
    is_active boolean,
    last_name character varying(255),
    middle_name character varying(255),
    mobile_no character varying(255),
    password character varying(255),
    username character varying(255),
    hospital_mst_id bigint,
    user_role_mst_id bigint
);


ALTER TABLE healspan.user_mst OWNER TO root;

--
-- TOC entry 391 (class 1259 OID 50147)
-- Name: get_sla_details; Type: VIEW; Schema: healspan; Owner: root
--

CREATE VIEW healspan.get_sla_details AS
 WITH cte_cla_list AS (
         SELECT csl.claim_info_id AS claim_id,
            csl.claim_stage_mst_id AS claim_stage_id,
            ca.completed_date_time,
            ca.assigned_date_time,
            ca.user_mst_id,
            EXTRACT(minute FROM (COALESCE((ca.completed_date_time)::timestamp with time zone, CURRENT_TIMESTAMP) - (ca.assigned_date_time)::timestamp with time zone)) AS difference
           FROM ((healspan.claim_assignment ca
             JOIN healspan.claim_stage_link csl ON ((csl.id = ca.claim_stage_link_id)))
             JOIN healspan.user_mst um ON ((ca.user_mst_id = um.id)))
          WHERE (um.user_role_mst_id = 3)
        ), cla_total_spenttime AS (
         SELECT
                CASE
                    WHEN (per_data.claim_stage_id = ANY (ARRAY[(1)::bigint, (2)::bigint])) THEN round(((per_data.total_spent_time / (15)::numeric) * (100)::numeric))
                    WHEN (per_data.claim_stage_id = ANY (ARRAY[(3)::bigint, (4)::bigint])) THEN round(((per_data.total_spent_time / (60)::numeric) * (100)::numeric))
                    ELSE (0)::numeric
                END AS cla_percent,
            per_data.claim_id,
            per_data.claim_stage_id,
            per_data.user_mst_id
           FROM ( SELECT cte_cla_list.claim_id,
                    cte_cla_list.claim_stage_id,
                    cte_cla_list.user_mst_id,
                    sum(cte_cla_list.difference) AS total_spent_time
                   FROM cte_cla_list
                  GROUP BY cte_cla_list.claim_id, cte_cla_list.claim_stage_id, cte_cla_list.user_mst_id) per_data
        )
 SELECT cla_total_spenttime.cla_percent AS sla_percent,
    cla_total_spenttime.claim_id,
    cla_total_spenttime.claim_stage_id,
    cla_total_spenttime.user_mst_id
   FROM cla_total_spenttime
  ORDER BY cla_total_spenttime.claim_id DESC;


ALTER TABLE healspan.get_sla_details OWNER TO root;

--
-- TOC entry 354 (class 1259 OID 49378)
-- Name: hospital_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.hospital_mst (
    id bigint NOT NULL,
    hospital_code character varying(255),
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying,
    about character varying(1024),
    address character varying(255),
    board_line_num character varying(255),
    gst_num character varying(255),
    hospital_id character varying(255),
    email_id character varying
);


ALTER TABLE healspan.hospital_mst OWNER TO root;

--
-- TOC entry 364 (class 1259 OID 49417)
-- Name: medical_info; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.medical_info (
    id bigint NOT NULL,
    date_of_first_diagnosis timestamp without time zone,
    doctor_name character varying(255),
    doctor_qualification character varying(255),
    doctor_registration_number character varying(255),
    diagnosis_mst_id bigint,
    procedure_mst_id bigint,
    speciality_mst_id bigint,
    treatment_type_mst_id bigint,
    other_information character varying(500)
);


ALTER TABLE healspan.medical_info OWNER TO root;

--
-- TOC entry 368 (class 1259 OID 49433)
-- Name: patient_info; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.patient_info (
    id bigint NOT NULL,
    age integer,
    bill_number character varying(255),
    claimed_amount double precision,
    cost_per_day double precision,
    date_of_birth timestamp without time zone,
    date_of_admission timestamp without time zone,
    date_of_discharge timestamp without time zone,
    enhancement_estimation double precision,
    estimated_date_of_discharge timestamp without time zone,
    final_bill_amount double precision,
    first_name character varying(255),
    patient_uhid character varying(255),
    initial_costs_estimation double precision,
    is_primary_insured boolean,
    last_name character varying(255),
    middle_name character varying(255),
    mobile_no character varying(255),
    other_costs_estimation double precision,
    total_room_cost double precision,
    gender_mst_id bigint,
    hospital_mst_id bigint,
    room_category_mst_id bigint
);


ALTER TABLE healspan.patient_info OWNER TO root;

--
-- TOC entry 382 (class 1259 OID 49502)
-- Name: status_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.status_mst (
    id bigint NOT NULL,
    name character varying(255),
    claim_stage_id bigint,
    user_role_mst_id bigint,
    is_active character varying(1)
);


ALTER TABLE healspan.status_mst OWNER TO root;

--
-- TOC entry 390 (class 1259 OID 49541)
-- Name: user_role_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.user_role_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.user_role_mst OWNER TO root;

--
-- TOC entry 392 (class 1259 OID 50152)
-- Name: get_claim_details; Type: VIEW; Schema: healspan; Owner: root
--

CREATE VIEW healspan.get_claim_details AS
 SELECT csl.id AS claim_stage_link_id,
    csl.claim_info_id,
    csl.claim_stage_mst_id AS claim_stage_id,
    concat(pin.first_name, ' ', ltrim(concat(' ', COALESCE(pin.middle_name, ''::character varying), ' ', COALESCE(pin.last_name, ''::character varying)), ' '::text)) AS full_name,
    csl.created_date_time,
    pin.date_of_discharge,
    dm.display_name AS ailment,
    csm.name AS claim_stage,
    sm.name AS claim_status,
    pin.claimed_amount AS approved_amount,
    hm.name AS hospital_name,
    gcd.user_mst_id,
    gcd.sla_percent,
    um.username,
    urm.name AS user_role
   FROM (((((((((healspan.get_sla_details gcd
     LEFT JOIN healspan.claim_stage_link csl ON (((gcd.claim_id = csl.claim_info_id) AND (gcd.claim_stage_id = csl.claim_stage_mst_id))))
     LEFT JOIN healspan.patient_info pin ON ((pin.id = csl.patient_info_id)))
     LEFT JOIN healspan.medical_info mi ON ((mi.id = csl.medical_info_id)))
     LEFT JOIN healspan.diagnosis_mst dm ON ((dm.id = mi.diagnosis_mst_id)))
     LEFT JOIN healspan.claim_stage_mst csm ON ((csm.id = csl.claim_stage_mst_id)))
     LEFT JOIN healspan.status_mst sm ON ((sm.id = csl.status_mst_id)))
     LEFT JOIN healspan.hospital_mst hm ON ((hm.id = pin.hospital_mst_id)))
     LEFT JOIN healspan.user_mst um ON ((um.id = gcd.user_mst_id)))
     LEFT JOIN healspan.user_role_mst urm ON ((urm.id = um.user_role_mst_id)))
  ORDER BY csl.id DESC;


ALTER TABLE healspan.get_claim_details OWNER TO root;

--
-- TOC entry 353 (class 1259 OID 49377)
-- Name: hospital_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.hospital_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.hospital_mst_id_seq OWNER TO root;

--
-- TOC entry 4908 (class 0 OID 0)
-- Dependencies: 353
-- Name: hospital_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.hospital_mst_id_seq OWNED BY healspan.hospital_mst.id;


--
-- TOC entry 356 (class 1259 OID 49387)
-- Name: insurance_company_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.insurance_company_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.insurance_company_mst OWNER TO root;

--
-- TOC entry 355 (class 1259 OID 49386)
-- Name: insurance_company_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.insurance_company_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.insurance_company_mst_id_seq OWNER TO root;

--
-- TOC entry 4909 (class 0 OID 0)
-- Dependencies: 355
-- Name: insurance_company_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.insurance_company_mst_id_seq OWNED BY healspan.insurance_company_mst.id;


--
-- TOC entry 358 (class 1259 OID 49394)
-- Name: insurance_info; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.insurance_info (
    id bigint NOT NULL,
    approval_amount_at_discharge double precision,
    approval_enhancement_amount double precision,
    claim_id_pre_auth_number character varying(255),
    group_company character varying(255),
    group_company_emp_id character varying(255),
    approval_amount_at_initial double precision,
    is_group_policy boolean,
    policy_holder_name character varying(255),
    policy_number character varying(255),
    tpa_id_card_number character varying(255),
    insurance_company_mst_id bigint,
    relationship_mst_id bigint,
    tpa_mst_id bigint,
    approval_amount_final_stage double precision,
    initial_approval_limit double precision,
    tpa_number character varying(255)
);


ALTER TABLE healspan.insurance_info OWNER TO root;

--
-- TOC entry 357 (class 1259 OID 49393)
-- Name: insurance_info_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.insurance_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.insurance_info_id_seq OWNER TO root;

--
-- TOC entry 4910 (class 0 OID 0)
-- Dependencies: 357
-- Name: insurance_info_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.insurance_info_id_seq OWNED BY healspan.insurance_info.id;


--
-- TOC entry 360 (class 1259 OID 49403)
-- Name: mandatory_documents_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.mandatory_documents_mst (
    id bigint NOT NULL,
    document_type_mst_id bigint,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.mandatory_documents_mst OWNER TO root;

--
-- TOC entry 359 (class 1259 OID 49402)
-- Name: mandatory_documents_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.mandatory_documents_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.mandatory_documents_mst_id_seq OWNER TO root;

--
-- TOC entry 4911 (class 0 OID 0)
-- Dependencies: 359
-- Name: mandatory_documents_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.mandatory_documents_mst_id_seq OWNED BY healspan.mandatory_documents_mst.id;


--
-- TOC entry 400 (class 1259 OID 69297)
-- Name: max_hospital_claim_id; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.max_hospital_claim_id (
    id integer NOT NULL,
    hospital_id integer,
    max_claim_id integer
);


ALTER TABLE healspan.max_hospital_claim_id OWNER TO root;

--
-- TOC entry 399 (class 1259 OID 69296)
-- Name: max_hospital_claim_id_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.max_hospital_claim_id_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.max_hospital_claim_id_id_seq OWNER TO root;

--
-- TOC entry 4912 (class 0 OID 0)
-- Dependencies: 399
-- Name: max_hospital_claim_id_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.max_hospital_claim_id_id_seq OWNED BY healspan.max_hospital_claim_id.id;


--
-- TOC entry 362 (class 1259 OID 49410)
-- Name: medical_chronic_illness_link; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.medical_chronic_illness_link (
    id bigint NOT NULL,
    chronic_illness_mst_id bigint,
    medical_info_id bigint
);


ALTER TABLE healspan.medical_chronic_illness_link OWNER TO root;

--
-- TOC entry 361 (class 1259 OID 49409)
-- Name: medical_chronic_illness_link_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.medical_chronic_illness_link_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.medical_chronic_illness_link_id_seq OWNER TO root;

--
-- TOC entry 4913 (class 0 OID 0)
-- Dependencies: 361
-- Name: medical_chronic_illness_link_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.medical_chronic_illness_link_id_seq OWNED BY healspan.medical_chronic_illness_link.id;


--
-- TOC entry 363 (class 1259 OID 49416)
-- Name: medical_info_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.medical_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.medical_info_id_seq OWNER TO root;

--
-- TOC entry 4914 (class 0 OID 0)
-- Dependencies: 363
-- Name: medical_info_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.medical_info_id_seq OWNED BY healspan.medical_info.id;


--
-- TOC entry 394 (class 1259 OID 54373)
-- Name: notification_config; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.notification_config (
    id integer NOT NULL,
    status_master_id integer,
    notification_text character varying(1000),
    hospital_user boolean,
    hs_user boolean
);


ALTER TABLE healspan.notification_config OWNER TO root;

--
-- TOC entry 393 (class 1259 OID 54372)
-- Name: notification_config_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.notification_config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.notification_config_id_seq OWNER TO root;

--
-- TOC entry 4915 (class 0 OID 0)
-- Dependencies: 393
-- Name: notification_config_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.notification_config_id_seq OWNED BY healspan.notification_config.id;


--
-- TOC entry 366 (class 1259 OID 49426)
-- Name: other_costs_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.other_costs_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.other_costs_mst OWNER TO root;

--
-- TOC entry 365 (class 1259 OID 49425)
-- Name: other_costs_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.other_costs_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.other_costs_mst_id_seq OWNER TO root;

--
-- TOC entry 4916 (class 0 OID 0)
-- Dependencies: 365
-- Name: other_costs_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.other_costs_mst_id_seq OWNED BY healspan.other_costs_mst.id;


--
-- TOC entry 367 (class 1259 OID 49432)
-- Name: patient_info_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.patient_info_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.patient_info_id_seq OWNER TO root;

--
-- TOC entry 4917 (class 0 OID 0)
-- Dependencies: 367
-- Name: patient_info_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.patient_info_id_seq OWNED BY healspan.patient_info.id;


--
-- TOC entry 370 (class 1259 OID 49442)
-- Name: patient_othercost_link; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.patient_othercost_link (
    id bigint NOT NULL,
    amount double precision,
    other_costs_mst_id bigint,
    patient_info_id bigint
);


ALTER TABLE healspan.patient_othercost_link OWNER TO root;

--
-- TOC entry 369 (class 1259 OID 49441)
-- Name: patient_othercost_link_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.patient_othercost_link_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.patient_othercost_link_id_seq OWNER TO root;

--
-- TOC entry 4918 (class 0 OID 0)
-- Dependencies: 369
-- Name: patient_othercost_link_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.patient_othercost_link_id_seq OWNED BY healspan.patient_othercost_link.id;


--
-- TOC entry 372 (class 1259 OID 49449)
-- Name: procedure_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.procedure_mst (
    id bigint NOT NULL,
    display_name character varying(255),
    rule_engine_name character varying(255),
    tpa_mst_id bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.procedure_mst OWNER TO root;

--
-- TOC entry 371 (class 1259 OID 49448)
-- Name: procedure_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.procedure_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.procedure_mst_id_seq OWNER TO root;

--
-- TOC entry 4919 (class 0 OID 0)
-- Dependencies: 371
-- Name: procedure_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.procedure_mst_id_seq OWNED BY healspan.procedure_mst.id;


--
-- TOC entry 374 (class 1259 OID 49458)
-- Name: question_answer; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.question_answer (
    id bigint NOT NULL,
    answers character varying(255),
    questions character varying(255),
    claim_stage_link_id bigint
);


ALTER TABLE healspan.question_answer OWNER TO root;

--
-- TOC entry 373 (class 1259 OID 49457)
-- Name: question_answer_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.question_answer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.question_answer_id_seq OWNER TO root;

--
-- TOC entry 4920 (class 0 OID 0)
-- Dependencies: 373
-- Name: question_answer_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.question_answer_id_seq OWNED BY healspan.question_answer.id;


--
-- TOC entry 411 (class 1259 OID 107080)
-- Name: relationship_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.relationship_mst (
    id bigint NOT NULL,
    name character varying(255),
    tpa_mst_id bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.relationship_mst OWNER TO root;

--
-- TOC entry 410 (class 1259 OID 107079)
-- Name: relationship_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.relationship_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.relationship_mst_id_seq OWNER TO root;

--
-- TOC entry 4921 (class 0 OID 0)
-- Dependencies: 410
-- Name: relationship_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.relationship_mst_id_seq OWNED BY healspan.relationship_mst.id;


--
-- TOC entry 413 (class 1259 OID 107128)
-- Name: room_category_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.room_category_mst (
    id bigint NOT NULL,
    name character varying(255),
    tpa_mst_id bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.room_category_mst OWNER TO root;

--
-- TOC entry 412 (class 1259 OID 107127)
-- Name: room_category_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.room_category_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.room_category_mst_id_seq OWNER TO root;

--
-- TOC entry 4922 (class 0 OID 0)
-- Dependencies: 412
-- Name: room_category_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.room_category_mst_id_seq OWNED BY healspan.room_category_mst.id;


--
-- TOC entry 376 (class 1259 OID 49481)
-- Name: sla_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.sla_mst (
    id bigint NOT NULL,
    discharge_sla bigint,
    enhancement_sla bigint,
    final_claim_sla bigint,
    initial_authorization_sla bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.sla_mst OWNER TO root;

--
-- TOC entry 375 (class 1259 OID 49480)
-- Name: sla_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.sla_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.sla_mst_id_seq OWNER TO root;

--
-- TOC entry 4923 (class 0 OID 0)
-- Dependencies: 375
-- Name: sla_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.sla_mst_id_seq OWNED BY healspan.sla_mst.id;


--
-- TOC entry 378 (class 1259 OID 49488)
-- Name: speciality_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.speciality_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.speciality_mst OWNER TO root;

--
-- TOC entry 377 (class 1259 OID 49487)
-- Name: speciality_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.speciality_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.speciality_mst_id_seq OWNER TO root;

--
-- TOC entry 4924 (class 0 OID 0)
-- Dependencies: 377
-- Name: speciality_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.speciality_mst_id_seq OWNED BY healspan.speciality_mst.id;


--
-- TOC entry 380 (class 1259 OID 49495)
-- Name: stage_and_document_link_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.stage_and_document_link_mst (
    id bigint NOT NULL,
    claim_stage_mst_id bigint,
    mandatory_documents_mst_id bigint,
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.stage_and_document_link_mst OWNER TO root;

--
-- TOC entry 379 (class 1259 OID 49494)
-- Name: stage_and_document_link_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.stage_and_document_link_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.stage_and_document_link_mst_id_seq OWNER TO root;

--
-- TOC entry 4925 (class 0 OID 0)
-- Dependencies: 379
-- Name: stage_and_document_link_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.stage_and_document_link_mst_id_seq OWNED BY healspan.stage_and_document_link_mst.id;


--
-- TOC entry 381 (class 1259 OID 49501)
-- Name: status_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.status_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.status_mst_id_seq OWNER TO root;

--
-- TOC entry 4926 (class 0 OID 0)
-- Dependencies: 381
-- Name: status_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.status_mst_id_seq OWNED BY healspan.status_mst.id;


--
-- TOC entry 384 (class 1259 OID 49509)
-- Name: tpa_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.tpa_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying,
    code character varying
);


ALTER TABLE healspan.tpa_mst OWNER TO root;

--
-- TOC entry 383 (class 1259 OID 49508)
-- Name: tpa_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.tpa_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.tpa_mst_id_seq OWNER TO root;

--
-- TOC entry 4927 (class 0 OID 0)
-- Dependencies: 383
-- Name: tpa_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.tpa_mst_id_seq OWNED BY healspan.tpa_mst.id;


--
-- TOC entry 402 (class 1259 OID 78328)
-- Name: tpa_update; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.tpa_update (
    id bigint NOT NULL,
    approved_amount numeric,
    settled_amount numeric,
    remarks character varying(2550),
    tpa_claim_number character varying(255),
    status character varying(255),
    claim_stage_id bigint,
    status_mst_id integer,
    claim_stage_link_id bigint,
    claim_info_id bigint,
    created_datetime timestamp without time zone,
    record_insertion_date timestamp without time zone
);


ALTER TABLE healspan.tpa_update OWNER TO root;

--
-- TOC entry 401 (class 1259 OID 78327)
-- Name: tpa_update_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.tpa_update_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.tpa_update_id_seq OWNER TO root;

--
-- TOC entry 4928 (class 0 OID 0)
-- Dependencies: 401
-- Name: tpa_update_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.tpa_update_id_seq OWNED BY healspan.tpa_update.id;


--
-- TOC entry 386 (class 1259 OID 49525)
-- Name: treatment_type_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.treatment_type_mst (
    id bigint NOT NULL,
    name character varying(255),
    is_active character varying(1) DEFAULT 'Y'::character varying
);


ALTER TABLE healspan.treatment_type_mst OWNER TO root;

--
-- TOC entry 385 (class 1259 OID 49524)
-- Name: treatment_type_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.treatment_type_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.treatment_type_mst_id_seq OWNER TO root;

--
-- TOC entry 4929 (class 0 OID 0)
-- Dependencies: 385
-- Name: treatment_type_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.treatment_type_mst_id_seq OWNED BY healspan.treatment_type_mst.id;


--
-- TOC entry 387 (class 1259 OID 49531)
-- Name: user_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.user_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.user_mst_id_seq OWNER TO root;

--
-- TOC entry 4930 (class 0 OID 0)
-- Dependencies: 387
-- Name: user_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.user_mst_id_seq OWNED BY healspan.user_mst.id;


--
-- TOC entry 396 (class 1259 OID 54827)
-- Name: user_notification; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.user_notification (
    id integer NOT NULL,
    notification_config_id integer,
    claim_info_id integer,
    stage_master_id integer,
    status_master_id integer,
    notification_text character varying(1000),
    user_mst_id integer,
    created_datetime timestamp without time zone,
    read_datetime timestamp without time zone
);


ALTER TABLE healspan.user_notification OWNER TO root;

--
-- TOC entry 395 (class 1259 OID 54826)
-- Name: user_notification_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.user_notification_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.user_notification_id_seq OWNER TO root;

--
-- TOC entry 4931 (class 0 OID 0)
-- Dependencies: 395
-- Name: user_notification_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.user_notification_id_seq OWNED BY healspan.user_notification.id;


--
-- TOC entry 389 (class 1259 OID 49540)
-- Name: user_role_mst_id_seq; Type: SEQUENCE; Schema: healspan; Owner: root
--

CREATE SEQUENCE healspan.user_role_mst_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE healspan.user_role_mst_id_seq OWNER TO root;

--
-- TOC entry 4932 (class 0 OID 0)
-- Dependencies: 389
-- Name: user_role_mst_id_seq; Type: SEQUENCE OWNED BY; Schema: healspan; Owner: root
--

ALTER SEQUENCE healspan.user_role_mst_id_seq OWNED BY healspan.user_role_mst.id;


--
-- TOC entry 416 (class 1259 OID 112336)
-- Name: v_doclist; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.v_doclist (
    string_agg text
);


ALTER TABLE healspan.v_doclist OWNER TO root;

--
-- TOC entry 417 (class 1259 OID 133425)
-- Name: v_hospital_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.v_hospital_mst (
    json_build_object json
);


ALTER TABLE healspan.v_hospital_mst OWNER TO root;

--
-- TOC entry 415 (class 1259 OID 111517)
-- Name: v_tpa_mst; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.v_tpa_mst (
    json_build_object json
);


ALTER TABLE healspan.v_tpa_mst OWNER TO root;

--
-- TOC entry 414 (class 1259 OID 110117)
-- Name: v_tpa_response; Type: TABLE; Schema: healspan; Owner: root
--

CREATE TABLE healspan.v_tpa_response (
    json_build_object json
);


ALTER TABLE healspan.v_tpa_response OWNER TO root;

--
-- TOC entry 4550 (class 2604 OID 87000)
-- Name: app_error_log id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.app_error_log ALTER COLUMN id SET DEFAULT nextval('healspan.app_error_log_id_seq'::regclass);


--
-- TOC entry 4501 (class 2604 OID 87001)
-- Name: chronic_illness_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.chronic_illness_mst ALTER COLUMN id SET DEFAULT nextval('healspan.chronic_illness_mst_id_seq'::regclass);


--
-- TOC entry 4503 (class 2604 OID 87002)
-- Name: claim_assignment id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment ALTER COLUMN id SET DEFAULT nextval('healspan.claim_assignment_id_seq'::regclass);


--
-- TOC entry 4504 (class 2604 OID 87003)
-- Name: claim_info id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_info ALTER COLUMN id SET DEFAULT nextval('healspan.claim_info_id_seq'::regclass);


--
-- TOC entry 4505 (class 2604 OID 87004)
-- Name: claim_stage_link id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link ALTER COLUMN id SET DEFAULT nextval('healspan.claim_stage_link_id_seq'::regclass);


--
-- TOC entry 4506 (class 2604 OID 87005)
-- Name: claim_stage_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_mst ALTER COLUMN id SET DEFAULT nextval('healspan.claim_stage_mst_id_seq'::regclass);


--
-- TOC entry 4546 (class 2604 OID 87006)
-- Name: contact_type id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.contact_type ALTER COLUMN id SET DEFAULT nextval('healspan.contact_type_id_seq'::regclass);


--
-- TOC entry 4508 (class 2604 OID 87007)
-- Name: diagnosis_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.diagnosis_mst ALTER COLUMN id SET DEFAULT nextval('healspan.diagnosis_mst_id_seq'::regclass);


--
-- TOC entry 4510 (class 2604 OID 87008)
-- Name: document id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.document ALTER COLUMN id SET DEFAULT nextval('healspan.document_id_seq'::regclass);


--
-- TOC entry 4512 (class 2604 OID 87009)
-- Name: document_type_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.document_type_mst ALTER COLUMN id SET DEFAULT nextval('healspan.document_type_mst_id_seq'::regclass);


--
-- TOC entry 4551 (class 2604 OID 107076)
-- Name: gender_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.gender_mst ALTER COLUMN id SET DEFAULT nextval('healspan.gender_mst_id_seq'::regclass);


--
-- TOC entry 4514 (class 2604 OID 87011)
-- Name: hospital_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.hospital_mst ALTER COLUMN id SET DEFAULT nextval('healspan.hospital_mst_id_seq'::regclass);


--
-- TOC entry 4516 (class 2604 OID 87012)
-- Name: insurance_company_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_company_mst ALTER COLUMN id SET DEFAULT nextval('healspan.insurance_company_mst_id_seq'::regclass);


--
-- TOC entry 4518 (class 2604 OID 87013)
-- Name: insurance_info id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_info ALTER COLUMN id SET DEFAULT nextval('healspan.insurance_info_id_seq'::regclass);


--
-- TOC entry 4519 (class 2604 OID 87014)
-- Name: mandatory_documents_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.mandatory_documents_mst ALTER COLUMN id SET DEFAULT nextval('healspan.mandatory_documents_mst_id_seq'::regclass);


--
-- TOC entry 4548 (class 2604 OID 87015)
-- Name: max_hospital_claim_id id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.max_hospital_claim_id ALTER COLUMN id SET DEFAULT nextval('healspan.max_hospital_claim_id_id_seq'::regclass);


--
-- TOC entry 4521 (class 2604 OID 87016)
-- Name: medical_chronic_illness_link id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_chronic_illness_link ALTER COLUMN id SET DEFAULT nextval('healspan.medical_chronic_illness_link_id_seq'::regclass);


--
-- TOC entry 4522 (class 2604 OID 87017)
-- Name: medical_info id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_info ALTER COLUMN id SET DEFAULT nextval('healspan.medical_info_id_seq'::regclass);


--
-- TOC entry 4544 (class 2604 OID 87018)
-- Name: notification_config id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.notification_config ALTER COLUMN id SET DEFAULT nextval('healspan.notification_config_id_seq'::regclass);


--
-- TOC entry 4523 (class 2604 OID 87019)
-- Name: other_costs_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.other_costs_mst ALTER COLUMN id SET DEFAULT nextval('healspan.other_costs_mst_id_seq'::regclass);


--
-- TOC entry 4525 (class 2604 OID 87020)
-- Name: patient_info id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_info ALTER COLUMN id SET DEFAULT nextval('healspan.patient_info_id_seq'::regclass);


--
-- TOC entry 4526 (class 2604 OID 87021)
-- Name: patient_othercost_link id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_othercost_link ALTER COLUMN id SET DEFAULT nextval('healspan.patient_othercost_link_id_seq'::regclass);


--
-- TOC entry 4528 (class 2604 OID 87022)
-- Name: procedure_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.procedure_mst ALTER COLUMN id SET DEFAULT nextval('healspan.procedure_mst_id_seq'::regclass);


--
-- TOC entry 4529 (class 2604 OID 87023)
-- Name: question_answer id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.question_answer ALTER COLUMN id SET DEFAULT nextval('healspan.question_answer_id_seq'::regclass);


--
-- TOC entry 4553 (class 2604 OID 107083)
-- Name: relationship_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.relationship_mst ALTER COLUMN id SET DEFAULT nextval('healspan.relationship_mst_id_seq'::regclass);


--
-- TOC entry 4555 (class 2604 OID 107131)
-- Name: room_category_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.room_category_mst ALTER COLUMN id SET DEFAULT nextval('healspan.room_category_mst_id_seq'::regclass);


--
-- TOC entry 4531 (class 2604 OID 87026)
-- Name: sla_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.sla_mst ALTER COLUMN id SET DEFAULT nextval('healspan.sla_mst_id_seq'::regclass);


--
-- TOC entry 4533 (class 2604 OID 87027)
-- Name: speciality_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.speciality_mst ALTER COLUMN id SET DEFAULT nextval('healspan.speciality_mst_id_seq'::regclass);


--
-- TOC entry 4535 (class 2604 OID 87028)
-- Name: stage_and_document_link_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.stage_and_document_link_mst ALTER COLUMN id SET DEFAULT nextval('healspan.stage_and_document_link_mst_id_seq'::regclass);


--
-- TOC entry 4536 (class 2604 OID 87029)
-- Name: status_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.status_mst ALTER COLUMN id SET DEFAULT nextval('healspan.status_mst_id_seq'::regclass);


--
-- TOC entry 4538 (class 2604 OID 87030)
-- Name: tpa_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_mst ALTER COLUMN id SET DEFAULT nextval('healspan.tpa_mst_id_seq'::regclass);


--
-- TOC entry 4549 (class 2604 OID 87031)
-- Name: tpa_update id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_update ALTER COLUMN id SET DEFAULT nextval('healspan.tpa_update_id_seq'::regclass);


--
-- TOC entry 4540 (class 2604 OID 87032)
-- Name: treatment_type_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.treatment_type_mst ALTER COLUMN id SET DEFAULT nextval('healspan.treatment_type_mst_id_seq'::regclass);


--
-- TOC entry 4541 (class 2604 OID 87033)
-- Name: user_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_mst ALTER COLUMN id SET DEFAULT nextval('healspan.user_mst_id_seq'::regclass);


--
-- TOC entry 4545 (class 2604 OID 87034)
-- Name: user_notification id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_notification ALTER COLUMN id SET DEFAULT nextval('healspan.user_notification_id_seq'::regclass);


--
-- TOC entry 4543 (class 2604 OID 87036)
-- Name: user_role_mst id; Type: DEFAULT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_role_mst ALTER COLUMN id SET DEFAULT nextval('healspan.user_role_mst_id_seq'::regclass);


--
-- TOC entry 4880 (class 0 OID 85211)
-- Dependencies: 404
-- Data for Name: app_error_log; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4816 (class 0 OID 49309)
-- Dependencies: 338
-- Data for Name: chronic_illness_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.chronic_illness_mst VALUES (1, 'Acute Illness', 'Y');
INSERT INTO healspan.chronic_illness_mst VALUES (2, 'Acute Onset Chronic Illness', 'Y');
INSERT INTO healspan.chronic_illness_mst VALUES (3, 'Chronic Illnesses', 'Y');
INSERT INTO healspan.chronic_illness_mst VALUES (4, 'Sub Acute Illnes', 'Y');


--
-- TOC entry 4818 (class 0 OID 49316)
-- Dependencies: 340
-- Data for Name: claim_assignment; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4820 (class 0 OID 49325)
-- Dependencies: 342
-- Data for Name: claim_info; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4822 (class 0 OID 49332)
-- Dependencies: 344
-- Data for Name: claim_stage_link; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4824 (class 0 OID 49339)
-- Dependencies: 346
-- Data for Name: claim_stage_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.claim_stage_mst VALUES (1, 'Initial Authorization', 'Y', 15);
INSERT INTO healspan.claim_stage_mst VALUES (2, 'Enhancement', 'Y', 15);
INSERT INTO healspan.claim_stage_mst VALUES (3, 'Discharge', 'Y', 60);
INSERT INTO healspan.claim_stage_mst VALUES (4, 'Final Claim', 'Y', 60);


--
-- TOC entry 4874 (class 0 OID 66374)
-- Dependencies: 398
-- Data for Name: contact_type; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.contact_type VALUES (1, ' +91 7306906746', NULL, 'Anil ', 'Y', NULL, 3, NULL);
INSERT INTO healspan.contact_type VALUES (2, '+91 9154087324', NULL, 'Mahesh', 'Y', NULL, 3, NULL);
INSERT INTO healspan.contact_type VALUES (3, '7899888888888', 'tee@h.com', 'yash', 'Y', 'JOSHI', 1, NULL);
INSERT INTO healspan.contact_type VALUES (5, '56456464644', 'HJJJ@H.COM', 'John', 'Y', 'Pathak', 2, NULL);
INSERT INTO healspan.contact_type VALUES (6, '545454644646', 'jkk@j.com', 'Ram', 'Y', 'Charan', 2, NULL);
INSERT INTO healspan.contact_type VALUES (4, '8899999999', 'hghgh@h', 'MANISH', 'Y', 'JOSHI', 1, NULL);


--
-- TOC entry 4826 (class 0 OID 49346)
-- Dependencies: 348
-- Data for Name: diagnosis_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.diagnosis_mst VALUES (3, 'Single Spontaneous Delivery', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (4, 'Single delivery by forceps and vaccuum extractor', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (5, 'Single delivery by Caesarean Section', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (6, 'Other assisted delivery', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (7, 'Multiple delivery', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (8, 'Outcome of delivery', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (9, 'Preterm labour and delivery', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (10, 'Preterm labour and preterm delivery', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (11, 'Term delivery with preterm labour, third trimester', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (12, 'Other complications of labour and delivery, not elsewhere classified', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (13, 'MTP', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (14, 'Ectopic Pregnancy', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (15, 'Complications following abortion and ectopic and molar pregnancy', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (16, 'Failed attempted abortion', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (17, 'Medical abortion', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (18, 'Spontaneous abortion', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (19, 'Other abortion', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (20, 'Unspecified abortion', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (21, 'Eclampsia', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (22, 'Hyperemesis Gravidarum', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (23, 'Gestational Diabetes', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (24, 'UTI in pregnancy', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (25, 'Anemia in pregnancy', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (26, 'PPH', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (27, 'PIH', 'Maternity', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (28, 'Single Spontaneous Delivery', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (29, 'Single delivery by forceps and vaccuum extractor', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (30, 'Single delivery by Caesarean Section', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (31, 'Other assisted delivery', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (32, 'Multiple delivery', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (33, 'Outcome of delivery', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (34, 'Preterm labour and delivery', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (35, 'Preterm labour and preterm delivery', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (36, 'Term delivery with preterm labour, third trimester', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (37, 'Other complications of labour and delivery, not elsewhere classified', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (38, 'MTP', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (39, 'Ectopic Pregnancy', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (40, 'Complications following abortion and ectopic and molar pregnancy', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (41, 'Failed attempted abortion', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (42, 'Medical abortion', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (43, 'Spontaneous abortion', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (44, 'Other abortion', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (45, 'Unspecified abortion', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (46, 'Eclampsia', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (47, 'Hyperemesis Gravidarum', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (48, 'Gestational Diabetes', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (49, 'UTI in pregnancy', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (50, 'Anemia in pregnancy', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (51, 'PPH', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (52, 'PIH', 'Maternity', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (53, 'Varicose Veins of lower extremities', 'Vericose Veins', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (54, 'Varicose veins of other sites', 'Vericose Veins', 2, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (55, 'Varicose Veins of lower extremities', 'Vericose Veins', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (56, 'Varicose veins of other sites', 'Vericose Veins', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (57, 'Vericose Veins', 'Vericose Veins', 6, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (58, 'Single Spontaneous Delivery', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (59, 'Single delivery by forceps and vaccuum extractor', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (60, 'Single delivery by Caesarean Section', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (61, 'Other assisted delivery', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (62, 'Multiple delivery', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (63, 'Outcome of delivery', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (64, 'Preterm labour and delivery', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (65, 'Preterm labour and preterm delivery', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (66, 'Term delivery with preterm labour, third trimester', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (67, 'Other complications of labour and delivery, not elsewhere classified', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (68, 'MTP', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (69, 'Ectopic Pregnancy', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (70, 'Complications following abortion and ectopic and molar pregnancy', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (71, 'Failed attempted abortion', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (72, 'Medical abortion', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (73, 'Spontaneous abortion', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (74, 'Other abortion', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (75, 'Unspecified abortion', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (76, 'Eclampsia', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (77, 'Hyperemesis Gravidarum', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (78, 'Gestational Diabetes', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (79, 'UTI in pregnancy', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (80, 'Anemia in pregnancy', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (81, 'PPH', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (82, 'PIH', 'Maternity', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (83, 'Varicose Veins of lower extremities', 'Vericose Veins', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (84, 'Varicose veins of other sites', 'Vericose Veins', 8, 'Y');
INSERT INTO healspan.diagnosis_mst VALUES (85, 'Vericose Veins', 'Vericose Veins', 8, 'Y');


--
-- TOC entry 4828 (class 0 OID 49355)
-- Dependencies: 350
-- Data for Name: document; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4830 (class 0 OID 49364)
-- Dependencies: 352
-- Data for Name: document_type_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.document_type_mst VALUES (1, 'Mandatory', 'Y');
INSERT INTO healspan.document_type_mst VALUES (2, 'Rule Engine', 'Y');
INSERT INTO healspan.document_type_mst VALUES (3, 'Reviewer', 'Y');
INSERT INTO healspan.document_type_mst VALUES (4, 'Other', 'Y');


--
-- TOC entry 4882 (class 0 OID 107073)
-- Dependencies: 409
-- Data for Name: gender_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.gender_mst VALUES (2, 'Female', 6, 'Y');
INSERT INTO healspan.gender_mst VALUES (3, 'Others', 6, 'Y');
INSERT INTO healspan.gender_mst VALUES (4, 'Male', 2, 'Y');
INSERT INTO healspan.gender_mst VALUES (1, 'Male', 6, 'Y');
INSERT INTO healspan.gender_mst VALUES (5, 'Female', 2, 'Y');
INSERT INTO healspan.gender_mst VALUES (6, 'Transgender', 2, 'Y');
INSERT INTO healspan.gender_mst VALUES (7, 'Male', 8, 'Y');
INSERT INTO healspan.gender_mst VALUES (8, 'Female', 8, 'Y');
INSERT INTO healspan.gender_mst VALUES (9, 'Transgender', 8, 'Y');


--
-- TOC entry 4832 (class 0 OID 49378)
-- Dependencies: 354
-- Data for Name: hospital_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.hospital_mst VALUES (4, 'LVT', 'Lilavati', 'Y', 'We are a premier multi-specialty tertiary care hospital of India and have been acknowledged globally as the centre of medical excellence. Over the years, Lilavati Hospital & Research Centre has Prodeloped unmatched trust with its patients on the basis of a strong foundation which includes the state-of-the-art facilities, best medical expertise, research, education and charitable endeavours. We are extremely proud that today, we serve patients from all walks of life and not only national but also international. We believe in ‘Sarvetra Sukhinah:Santu, Sarve Santu Niramaya:’ which means ‘Let all be blissful, Let all stay healthy’. Our approach and attitude have always been with a human touch; which truly reflects the essence of our motto “More than Healthcare, Human Care”.', 'A-791, A-791, Bandra Reclamation Rd, General Arunkumar Vaidya Nagar, Bandra West, Mumbai, Maharashtra 400050', '022-69318000 / 69301000', '27AAATL1398Q1ZW', '5966532149636', 'info@lilavatihospital.com');
INSERT INTO healspan.hospital_mst VALUES (2, 'JPT', 'Jupiter ', 'Y', 'Established in 2007, Jupiter Hospital is a tertiary care Hospital that lays its foundation on a ‘Patient first’ ideology and follows a Greenfield over Brownfield strategy for delivering leading-edge healthcare to cater to the changing needs of the growing populace. The first Jupiter hospital is situated in the vicinity of the arterial Eastern Express Highway in Thane, and is the epitome of medical innovations and quality healthcare that offers easy connectivity and accessibility to patients from all the nodes across Thane and Pune.', 'Service Rd, Eastern Express Hwy, next to Viviana Mall, Thane, Maharashtra 400601', '+91-22 6297 5555, +91-222 1725650, +91-222 1725555', '27AABCJ1982E1ZN', '5417254701358', 'info@jupiterhospital.com');
INSERT INTO healspan.hospital_mst VALUES (5, 'BET', 'Bethany ', 'Y', 'Bethany Hospital has put together surgical and clinical expertise of very high quality. This 190-bed, centrally air-conditioned hospital is fully equipped for world-class patient-centred medical and surgical services. It houses a state-of-the-art 24-hour trauma center with an operation theatre attached. Out-patient rooms and the latest diagnostic equipment including the cutting-edge Siemens 1.5 Tesla MRI Scanner, Multi-slice spiral CT-Scan, a 15-bed ICU, 16-bed ICCU, 12-bed NICU, delivery suite, dialysis room and state-of-the-art pathology and four modular Operation Theatres, along with a host of well-appointed wards are on par with Mumbai city’s finest.', 'Bethany Hospital, Pokharan Rd Number 2, Shastri Nagar, Thane West, Thane, Maharashtra 400606', '022 6911 5100, +91 9769443344', '17BDNPS1297L1ZQ', '9865986420000', 'info@bethanyhospital.in');
INSERT INTO healspan.hospital_mst VALUES (3, 'AVS', 'Avis', 'Y', 'Avis hospital is a full-service vascular healthcare and wound care hospital. We specialize in the non-surgical and minimally invasive treatment of a range of medical conditions namely Varicose Veins, Lymphedema, Uterine Fibroid Embolization, Deep Vein Thrombosis, Venous Leg Ulcers, Peripheral Artery Disease, Renal Artery Stenting and Varicocele.<br>Founded by Dr. Rajah V Koppala, Avis Vascular Centre has a state-of-the-art infrastructure and is well-equipped with all the latest medical amenities.<br>At Avis Vascular Centre, we only follow the USFDA approved procedures and have completed 16000+ procedures with a 95% success rate. For a better medical experience for all patients, we offer 100% price assurance at the time of admission itself.<br>To offer ease of Mediclaim settlements, we have partnered with all leading national insurance providers of India and have made all arrangements for cashless settlements as well.<br>Timings – Sunday to Saturday – 9 am to 6 pm', 'Plot no 99, Road No. 1, next to chiranjeevi blood bank, Jubilee Hills, Hyderabad, Telangana 500033.', '040- 22227799, +91 9989527715', '36AAICA9688H1Z1', '8900080336940', 'info@avishospitals.com');
INSERT INTO healspan.hospital_mst VALUES (1, 'FTZ03', 'Fortiz', 'Y', 'Fortis Healthcare Limited – an IHH Healthcare Berhad Company – is a leading integrated healthcare services provider in India. It is one of the largest healthcare organisations in the country with 36 healthcare facilities (including projects under Prodelopment), 4000 operational beds and over 400 diagnostics centres (including JVs). Fortis is present in India, United Arab Emirates (UAE) & Sri Lanka. The Company is listed on the BSE Ltd and National Stock Exchange (NSE) of India. It draws strength from its partnership with global major and parent company, IHH, to build upon its culture of world-class patient care and superlative clinical excellence. Fortis employs 23,000 people (including SRL) who share its vision of becoming the world’s most trusted healthcare network. Fortis offers a full spectrum of integrated healthcare services ranging from clinics to quaternary care facilities and a wide range of ancillary services.', 'Fortis Healthcare Limited, Corporate Office, Tower A, Unitech Business Park, Block – F, 3rd Floor, South City 1, Sector – 41, Gurgaon, Haryana- 122001', '022 6285 7001', '27AABCF3718N1ZE', '9854565421552', 'info@fortishealthcare.com');


--
-- TOC entry 4834 (class 0 OID 49387)
-- Dependencies: 356
-- Data for Name: insurance_company_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.insurance_company_mst VALUES (1, 'Acko General Insurance Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (2, 'Aditya Birla Health Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (3, 'Agriculture Insurance Company of India Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (4, 'Bajaj Allianz General Insurance Co. Ltd', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (5, 'Cholamandalam MS General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (6, 'Manipal Cigna Health Insurance Company Limited', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (7, 'Navi General Insurance Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (8, 'Edelweiss General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (9, 'ECGC Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (10, 'Future Generali India Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (11, 'Go Digit General Insurance Ltd', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (12, 'HDFC ERGO General Insurance Co.Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (13, 'ICICI LOMBARD General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (14, 'IFFCO TOKIO General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (15, 'Kotak Mahindra General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (16, 'Liberty General Insurance Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (17, 'Magma HDI General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (18, 'Niva Bupa Health Insurance Co Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (19, 'National Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (20, 'Raheja QBE General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (21, 'Reliance General Insurance Co.Ltd', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (22, 'Reliance Health Insurance Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (23, 'Care Health Insurance Ltd(formerly known as Religare Health Insurance Co. Ltd.)', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (24, 'Royal Sundaram General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (25, 'SBI General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (26, 'Shriram General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (27, 'Star Health & Allied Insurance Co.Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (28, 'Tata AIG General Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (29, 'The New India Assurance Co. Ltd', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (30, 'The Oriental Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (31, 'United India Insurance Co. Ltd.', 'Y');
INSERT INTO healspan.insurance_company_mst VALUES (32, 'Universal Sompo General Insurance Co. Ltd.', 'Y');


--
-- TOC entry 4836 (class 0 OID 49394)
-- Dependencies: 358
-- Data for Name: insurance_info; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4838 (class 0 OID 49403)
-- Dependencies: 360
-- Data for Name: mandatory_documents_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.mandatory_documents_mst VALUES (1, 1, 'Report supporting the diagnosis', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (2, 1, 'Patient address proof (Pref. Aadhar)', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (3, 1, 'Insured PAN Card', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (4, 1, 'Claim Form (Part A)', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (5, 1, 'All the reports pertaining to the lab bills submitted', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (6, 1, 'All medicine prescription papers for the medicine bills submitted', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (7, 1, 'Detailed IP costwise itemwise break up bill', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (8, 1, 'Detailed Discharge Summary', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (9, 1, 'Patient PAN Card', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (10, 1, 'Insurance card', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (11, 1, 'Final Bill', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (12, 1, 'Claim Form (Part A & B)', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (13, 1, 'Discharge Summary (with seal & signature)', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (14, 4, 'Other', 'Y');
INSERT INTO healspan.mandatory_documents_mst VALUES (15, 3, 'GIPSA Network Declaration Form', 'N');
INSERT INTO healspan.mandatory_documents_mst VALUES (16, 3, 'TPA ID Card', 'N');
INSERT INTO healspan.mandatory_documents_mst VALUES (17, 3, 'The Consultation Sheet', 'N');


--
-- TOC entry 4876 (class 0 OID 69297)
-- Dependencies: 400
-- Data for Name: max_hospital_claim_id; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4840 (class 0 OID 49410)
-- Dependencies: 362
-- Data for Name: medical_chronic_illness_link; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4842 (class 0 OID 49417)
-- Dependencies: 364
-- Data for Name: medical_info; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4870 (class 0 OID 54373)
-- Dependencies: 394
-- Data for Name: notification_config; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.notification_config VALUES (1, 1, 'The Claim ID - @claim_info_id is submited to you with status-Pending Documents', true, NULL);
INSERT INTO healspan.notification_config VALUES (2, 2, 'The Claim ID - @claim_info_id is submited to you with status-Pending HS Approval', NULL, true);
INSERT INTO healspan.notification_config VALUES (3, 3, 'The Claim ID - @claim_info_id is submited to you with status-Pending TPA Approval', true, NULL);
INSERT INTO healspan.notification_config VALUES (4, 4, 'The Claim ID - @claim_info_id is submited to you with status-TPA Query', NULL, true);
INSERT INTO healspan.notification_config VALUES (5, 5, 'The Claim ID - @claim_info_id is submited to you with status-Approved', true, true);
INSERT INTO healspan.notification_config VALUES (6, 6, 'The Claim ID - @claim_info_id is submited to you with status-Rejected', true, true);
INSERT INTO healspan.notification_config VALUES (7, 7, 'The Claim ID - @claim_info_id is submited to you with status-Pending Documents', true, NULL);
INSERT INTO healspan.notification_config VALUES (8, 8, 'The Claim ID - @claim_info_id is submited to you with status-Pending HS Approval', NULL, true);
INSERT INTO healspan.notification_config VALUES (9, 9, 'The Claim ID - @claim_info_id is submited to you with status-Pending TPA Approval', true, NULL);
INSERT INTO healspan.notification_config VALUES (10, 10, 'The Claim ID - @claim_info_id is submited to you with status-TPA Query', NULL, true);
INSERT INTO healspan.notification_config VALUES (11, 11, 'The Claim ID - @claim_info_id is submited to you with status-Approved', true, true);
INSERT INTO healspan.notification_config VALUES (12, 12, 'The Claim ID - @claim_info_id is submited to you with status-Rejected', true, true);
INSERT INTO healspan.notification_config VALUES (13, 13, 'The Claim ID - @claim_info_id is submited to you with status-Pending Documents', true, NULL);
INSERT INTO healspan.notification_config VALUES (14, 14, 'The Claim ID - @claim_info_id is submited to you with status-Pending HS Approval', NULL, true);
INSERT INTO healspan.notification_config VALUES (15, 15, 'The Claim ID - @claim_info_id is submited to you with status-Pending TPA Approval', true, NULL);
INSERT INTO healspan.notification_config VALUES (16, 16, 'The Claim ID - @claim_info_id is submited to you with status-TPA Query', NULL, true);
INSERT INTO healspan.notification_config VALUES (17, 17, 'The Claim ID - @claim_info_id is submited to you with status-Approved', true, true);
INSERT INTO healspan.notification_config VALUES (18, 18, 'The Claim ID - @claim_info_id is submited to you with status-Rejected', true, true);
INSERT INTO healspan.notification_config VALUES (19, 19, 'The Claim ID - @claim_info_id is submited to you with status-Pending Documents', true, NULL);
INSERT INTO healspan.notification_config VALUES (20, 20, 'The Claim ID - @claim_info_id is submited to you with status-Pending HS Approval', NULL, true);
INSERT INTO healspan.notification_config VALUES (21, 21, 'The Claim ID - @claim_info_id is submited to you with status-Hard copies to be sent', NULL, NULL);
INSERT INTO healspan.notification_config VALUES (22, 22, 'The Claim ID - @claim_info_id is submited to you with status-Documents dispatched', NULL, NULL);
INSERT INTO healspan.notification_config VALUES (23, 23, 'The Claim ID - @claim_info_id is submited to you with status-Pending TPA Approval', true, NULL);
INSERT INTO healspan.notification_config VALUES (24, 24, 'The Claim ID - @claim_info_id is submited to you with status-TPA Query', NULL, true);
INSERT INTO healspan.notification_config VALUES (25, 25, 'The Claim ID - @claim_info_id is submited to you with status-Approved', true, true);
INSERT INTO healspan.notification_config VALUES (26, 26, 'The Claim ID - @claim_info_id is submited to you with status-Settled', true, true);
INSERT INTO healspan.notification_config VALUES (27, 27, 'The Claim ID - @claim_info_id is submited to you with status-Rejected', true, true);


--
-- TOC entry 4844 (class 0 OID 49426)
-- Dependencies: 366
-- Data for Name: other_costs_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.other_costs_mst VALUES (1, 'Consultation', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (2, 'Consumables', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (3, 'Investigations', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (4, 'Medicines', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (5, 'OT Charges', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (6, 'Other Hospital Expenses', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (7, 'Package', 'Y');
INSERT INTO healspan.other_costs_mst VALUES (8, 'Surgeon & Anasthesia', 'Y');


--
-- TOC entry 4846 (class 0 OID 49433)
-- Dependencies: 368
-- Data for Name: patient_info; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4848 (class 0 OID 49442)
-- Dependencies: 370
-- Data for Name: patient_othercost_link; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4850 (class 0 OID 49449)
-- Dependencies: 372
-- Data for Name: procedure_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.procedure_mst VALUES (1, 'Normal Delivery/Spontaneous vertex delivery', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (2, 'Forceps Delivery/Instrumental delivery(Forces/Vaccuum)', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (3, 'Forceps Delivery', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (4, 'Other procedures associated with delivery', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (5, 'Instrumental Delivery', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (6, 'Normal Delivery', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (7, 'Breech Delivery and Extraction', 'Full Term Normal Delivery', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (8, 'Casearean Delivery(LSCS)', 'Lower Segment Caesarean Section', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (9, 'Lower Segment Cessarian Section(LSCS)', 'Lower Segment Caesarean Section', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (10, 'C- Section (LSCS)', 'Lower Segment Caesarean Section', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (11, 'Cervical Cerclage', 'Cervical Encerclage', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (12, 'Dilatation and Currettage', 'Dilatation and Currettage', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (13, 'Laproscopic Salpingectomy', 'Salphingectomy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (14, 'Laprotomy And Salphingectomy', 'Salphingectomy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (15, 'Laproscopy And Salphingectomy', 'Salphingectomy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (16, 'Medical Management', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (17, 'Normal Delivery', 'Full Term Normal Delivery', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (18, 'Normal Vaginal Delivery with Epidural Anaesthesia', 'Full Term Normal Delivery', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (19, 'Normal Vaginal Delivery in twins(Multiple Pregnancy)', 'Lower Segment Caesarean Section', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (20, 'Assisted Delivery', 'Full Term Normal Delivery', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (21, 'Instrumental Vaginal Delivery', 'Full Term Normal Delivery', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (22, 'Delivery in complicated Pregnancy', 'Lower Segment Caesarean Section', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (23, 'Ectopic pregnancy', 'Salphingectomy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (24, 'Dilatation and Evacuation(DnE)', 'Dilatation and Currettage', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (25, 'Abortion-Conservative Management', 'Dilatation and Currettage', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (26, 'Dilatation and Curettage(DnC)', 'Dilatation and Currettage', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (27, 'Caesarean Delivery with well baby care', 'Lower Segment Caesarean Section', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (28, 'Caesarean Delivery twins with well baby care', 'Lower Segment Caesarean Section', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (29, 'Complicated LSCS', 'Lower Segment Caesarean Section', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (30, 'Obstetrics-Medical Management', 'Dilatation and Currettage', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (31, 'Medical Management of Haemorrhagic shock in pregnancy', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (32, 'Gynec- conservative management', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (33, 'Medical Management/Hyperemesis Gravidarum management', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (34, 'diabetes complicating pregnancy management', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (35, 'Medical management', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (36, 'Moderate Anaemia management in pregnancy', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (37, 'Severe anemia management in pregnancy', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (38, 'Medical Mangaement of PPH', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (39, 'PIH Management', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (40, 'Management of Eclampsia with complications', 'Gestational Diabetes', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (41, 'Surgical Management of Abortion', 'Dilatation and Currettage', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (42, 'Medical management of Hypertensive cardiovascular disease in pregnancy', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (43, 'Heart disease complicating pregnancy management', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (44, 'Radiofrequency Ablation(RFA)', 'Radiofrequency Ablation', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (45, 'Radiofrequency Ablation', 'Radiofrequency Ablation', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (46, 'Ablation', 'Radiofrequency Ablation', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (47, 'Endovenous Ablation', 'Radiofrequency Ablation', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (48, 'Radiofrequency Ablation', 'Radiofrequency Ablation', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (49, 'Left Gsv Ablation And Foam Sclerotherapy', 'Sclerotherapy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (50, 'Endovenous Laser Therapy', 'Laser Therapy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (51, 'Laser', 'Laser Therapy', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (52, 'Ligation and Stripping', 'Vein Stripping', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (53, 'Stripping', 'Vein Stripping', 2, 'Y');
INSERT INTO healspan.procedure_mst VALUES (54, 'Varicose Veins- Laser Ablation- Right', 'Laser Therapy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (55, 'Varicose Veins- Laser Ablation- Left', 'Laser Therapy', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (56, 'Varicose Veins- Excision and Ligation- Left', 'Vein Stripping', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (57, 'Varicose Veins- Excision and Ligation- Right', 'Vein Stripping', 6, 'Y');
INSERT INTO healspan.procedure_mst VALUES (58, 'Normal Delivery/Spontaneous vertex delivery', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (59, 'Forceps Delivery/Instrumental delivery(Forces/Vaccuum)', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (60, 'Forceps Delivery', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (61, 'Other procedures associated with delivery', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (62, 'Instrumental Delivery', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (63, 'Normal Delivery', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (64, 'Breech Delivery and Extraction', 'Full Term Normal Delivery', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (65, 'Casearean Delivery(LSCS)', 'Lower Segment Caesarean Section', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (66, 'Lower Segment Cessarian Section(LSCS)', 'Lower Segment Caesarean Section', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (67, 'C- Section (LSCS)', 'Lower Segment Caesarean Section', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (68, 'Cervical Cerclage', 'Cervical Encerclage', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (69, 'Dilatation and Currettage', 'Dilatation and Currettage', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (70, 'Laproscopic Salpingectomy', 'Salphingectomy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (71, 'Laprotomy And Salphingectomy', 'Salphingectomy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (72, 'Laproscopy And Salphingectomy', 'Salphingectomy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (73, 'Medical Management', 'Threatened Abortion/Heamorrhage In Early Pregnancy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (74, 'Radiofrequency Ablation(RFA)', 'Radiofrequency Ablation', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (75, 'Radiofrequency Ablation', 'Radiofrequency Ablation', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (76, 'Ablation', 'Radiofrequency Ablation', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (77, 'Endovenous Ablation', 'Radiofrequency Ablation', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (78, 'Radiofrequency Ablation', 'Radiofrequency Ablation', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (79, 'Left Gsv Ablation And Foam Sclerotherapy', 'Sclerotherapy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (80, 'Endovenous Laser Therapy', 'Laser Therapy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (81, 'Laser', 'Laser Therapy', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (82, 'Ligation and Stripping', 'Vein Stripping', 8, 'Y');
INSERT INTO healspan.procedure_mst VALUES (83, 'Stripping', 'Vein Stripping', 8, 'Y');


--
-- TOC entry 4852 (class 0 OID 49458)
-- Dependencies: 374
-- Data for Name: question_answer; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4884 (class 0 OID 107080)
-- Dependencies: 411
-- Data for Name: relationship_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.relationship_mst VALUES (1, 'Aunty', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (2, 'Brother', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (3, 'Brother Daughter', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (4, 'Brother in law', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (5, 'Brother Son', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (6, 'Brother Wife', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (7, 'Co Brother', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (8, 'Cousin', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (9, 'Daughter', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (10, 'Daughter(D)', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (11, 'Daughter(W)', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (12, 'Daughterinlaw', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (13, 'Father', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (14, 'Father in law', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (15, 'Grand Daughter', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (16, 'Grand mother', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (17, 'Grandfather', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (18, 'Grandmother', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (19, 'Grandson', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (20, 'Great grandfather', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (21, 'Great grandmother', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (22, 'Husband', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (23, 'Mother', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (24, 'Mother in law', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (25, 'Nephew', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (26, 'Niece', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (27, 'None', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (28, 'Others', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (29, 'Self', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (30, 'Sister', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (31, 'Sister Daughter', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (32, 'Sister Husband', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (33, 'Sister in law', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (34, 'Sister Son', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (35, 'Sister(D)', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (36, 'Sister(W)', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (37, 'Son', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (38, 'Son in law', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (39, 'Spouse', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (41, 'Uncle', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (42, 'Wife', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (43, 'Self', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (44, 'Spouse', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (45, 'Father', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (46, 'Mother', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (47, 'Father in law', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (48, 'Mother in law', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (49, 'Son', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (50, 'Daughter', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (51, 'Sibling', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (52, 'Other', 2, 'Y');
INSERT INTO healspan.relationship_mst VALUES (40, 'Unknown', 6, 'Y');
INSERT INTO healspan.relationship_mst VALUES (53, 'Self', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (54, 'Spouse', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (55, 'Father', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (56, 'Mother', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (57, 'Father in law', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (58, 'Mother in law', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (59, 'Son', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (60, 'Daughter', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (61, 'Sibling', 8, 'Y');
INSERT INTO healspan.relationship_mst VALUES (62, 'Other', 8, 'Y');


--
-- TOC entry 4886 (class 0 OID 107128)
-- Dependencies: 413
-- Data for Name: room_category_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.room_category_mst VALUES (1, 'DayCare', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (2, 'Delux', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (3, 'General', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (4, 'ICU', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (5, 'Isolation', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (6, 'Luxury', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (7, 'Private', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (8, 'Semi Delux', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (9, 'Semi Private', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (10, 'Semi Pvt AC', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (11, 'Single AC Room', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (12, 'Single Room', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (13, 'Suite', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (14, 'Super Delux', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (16, 'Deluxe Room', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (17, 'General Ward', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (18, 'ICCU/SICU/MICU', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (19, 'Private Room AC', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (20, 'Semi Private', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (21, 'Burn Ward', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (22, 'Day Care', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (23, 'Delux Room', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (24, 'General/Economy Ward', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (25, 'HDU', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (26, 'ICU', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (27, 'Isolation Ward', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (29, 'Rehabilitation Room', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (30, 'Semi Deluxe Room', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (33, 'Suite', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (31, 'Semi Private Room', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (32, 'Single Private Room', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (28, 'Multi Bed Ward', 2, 'Y');
INSERT INTO healspan.room_category_mst VALUES (15, 'Super Luxury', 6, 'Y');
INSERT INTO healspan.room_category_mst VALUES (34, 'General Multi-Bed', 8, 'Y');
INSERT INTO healspan.room_category_mst VALUES (35, 'Single Room', 8, 'Y');
INSERT INTO healspan.room_category_mst VALUES (36, 'Semi-Private Shared', 8, 'Y');
INSERT INTO healspan.room_category_mst VALUES (37, 'Deluxe Room', 8, 'Y');
INSERT INTO healspan.room_category_mst VALUES (38, 'Single Room Deluxe', 8, 'Y');
INSERT INTO healspan.room_category_mst VALUES (39, 'Suite', 8, 'Y');


--
-- TOC entry 4854 (class 0 OID 49481)
-- Dependencies: 376
-- Data for Name: sla_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.sla_mst VALUES (1, 60, 15, 60, 15, 'Y');


--
-- TOC entry 4856 (class 0 OID 49488)
-- Dependencies: 378
-- Data for Name: speciality_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.speciality_mst VALUES (1, 'Neurology', 'Y');
INSERT INTO healspan.speciality_mst VALUES (2, 'Cardiology', 'Y');
INSERT INTO healspan.speciality_mst VALUES (3, 'CardioRespiratory', 'Y');
INSERT INTO healspan.speciality_mst VALUES (4, 'Opthalmology', 'Y');
INSERT INTO healspan.speciality_mst VALUES (5, 'Nephrology', 'Y');
INSERT INTO healspan.speciality_mst VALUES (6, 'Endocrinology', 'Y');
INSERT INTO healspan.speciality_mst VALUES (7, 'Muskuloskeletal', 'Y');
INSERT INTO healspan.speciality_mst VALUES (8, 'Obs and Gynacecology', 'Y');
INSERT INTO healspan.speciality_mst VALUES (9, 'General Medicine', 'Y');
INSERT INTO healspan.speciality_mst VALUES (10, 'General Surgery', 'Y');


--
-- TOC entry 4858 (class 0 OID 49495)
-- Dependencies: 380
-- Data for Name: stage_and_document_link_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.stage_and_document_link_mst VALUES (2, 1, 1, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (3, 1, 2, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (4, 1, 3, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (5, 1, 4, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (6, 2, 1, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (7, 2, 2, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (8, 2, 3, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (9, 2, 4, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (10, 3, 1, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (11, 3, 2, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (12, 3, 3, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (13, 3, 4, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (14, 3, 5, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (15, 3, 6, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (16, 3, 7, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (17, 3, 8, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (18, 4, 1, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (19, 4, 2, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (20, 4, 3, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (21, 4, 4, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (22, 4, 5, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (23, 4, 6, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (24, 4, 7, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (25, 4, 8, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (26, 4, 9, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (27, 4, 10, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (28, 4, 11, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (29, 4, 12, 'Y');
INSERT INTO healspan.stage_and_document_link_mst VALUES (30, 4, 13, 'Y');


--
-- TOC entry 4860 (class 0 OID 49502)
-- Dependencies: 382
-- Data for Name: status_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.status_mst VALUES (1, 'Pending Documents', 1, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (2, 'Pending HS Approval', 1, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (3, 'Pending TPA Approval', 1, 5, 'Y');
INSERT INTO healspan.status_mst VALUES (4, 'TPA Query', 1, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (5, 'Approved', 1, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (6, 'Rejected', 1, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (7, 'Pending Documents', 2, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (8, 'Pending HS Approval', 2, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (9, 'Pending TPA Approval', 2, 5, 'Y');
INSERT INTO healspan.status_mst VALUES (10, 'TPA Query', 2, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (11, 'Approved', 2, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (12, 'Rejected', 2, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (13, 'Pending Documents', 3, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (14, 'Pending HS Approval', 3, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (15, 'Pending TPA Approval', 3, 5, 'Y');
INSERT INTO healspan.status_mst VALUES (16, 'TPA Query', 3, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (17, 'Approved', 3, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (18, 'Rejected', 3, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (19, 'Pending Documents', 4, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (20, 'Pending HS Approval', 4, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (23, 'Pending TPA Approval', 4, 5, 'Y');
INSERT INTO healspan.status_mst VALUES (24, 'TPA Query', 4, 3, 'Y');
INSERT INTO healspan.status_mst VALUES (25, 'Approved', 4, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (26, 'Settled', 4, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (27, 'Rejected', 4, 2, 'Y');
INSERT INTO healspan.status_mst VALUES (21, 'Hard copies to be sent', 4, 4, 'Y');
INSERT INTO healspan.status_mst VALUES (22, 'Documents dispatched', 4, 4, 'Y');


--
-- TOC entry 4862 (class 0 OID 49509)
-- Dependencies: 384
-- Data for Name: tpa_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.tpa_mst VALUES (2, 'Medi Assist Insurance TPA Private Limited', 'Y', 'MAIPL');
INSERT INTO healspan.tpa_mst VALUES (6, 'Family Health Plan Insurance TPA Limited', 'Y', 'FHPL');
INSERT INTO healspan.tpa_mst VALUES (4, 'Paramount Health Services & Insurance TPA Private Limited', 'N', 'PHSPL');
INSERT INTO healspan.tpa_mst VALUES (5, 'Heritage Health Insurance TPA Private Limited', 'N', 'HHIPL');
INSERT INTO healspan.tpa_mst VALUES (7, 'Raksha Health Insurance TPA Private Limited', 'N', 'RHIPL');
INSERT INTO healspan.tpa_mst VALUES (9, 'East West Assist Insurance TPA Private Limited', 'N', 'EWAIPL');
INSERT INTO healspan.tpa_mst VALUES (10, 'Medsave Health Insurance TPA Limited', 'N', 'MHIL');
INSERT INTO healspan.tpa_mst VALUES (11, 'Genins India Insurance TPA Limited', 'N', 'GIIL');
INSERT INTO healspan.tpa_mst VALUES (12, 'Health India Insurance TPA Services Private Limited', 'N', 'HIISPL');
INSERT INTO healspan.tpa_mst VALUES (13, 'Good Health Insurance TPA Limited', 'N', 'GHIL');
INSERT INTO healspan.tpa_mst VALUES (14, 'Park Mediclaim Insurance TPA Private Limited', 'N', 'PMIPL');
INSERT INTO healspan.tpa_mst VALUES (15, 'Safeway Insurance TPA Private Limited', 'N', 'SIPL');
INSERT INTO healspan.tpa_mst VALUES (16, 'Anmol Medicare Insurance TPA Limited', 'N', 'AMIL');
INSERT INTO healspan.tpa_mst VALUES (17, 'Rothshield Insurance TPA Limited', 'N', 'RIL');
INSERT INTO healspan.tpa_mst VALUES (18, 'Ericson Insurance TPA Private Limited', 'N', 'EIPL');
INSERT INTO healspan.tpa_mst VALUES (19, 'Health Insurance TPA of India Limited', 'N', 'HIIL');
INSERT INTO healspan.tpa_mst VALUES (20, 'Vision Digital Insurance TPA Private Limited', 'N', 'VDIPL');
INSERT INTO healspan.tpa_mst VALUES (8, 'Vidal Health Insurance TPA Private Limited', 'Y', 'VHIPL');
INSERT INTO healspan.tpa_mst VALUES (1, 'Medvantage Insurance TPA Private Limited (formerly known as United Health Care Parekh Insurance TPA Private Limited)', 'N', 'MIPL');
INSERT INTO healspan.tpa_mst VALUES (3, 'MDIndia Health Insurance TPA Private Limited', 'N', 'MHIPL');


--
-- TOC entry 4878 (class 0 OID 78328)
-- Dependencies: 402
-- Data for Name: tpa_update; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4864 (class 0 OID 49525)
-- Dependencies: 386
-- Data for Name: treatment_type_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.treatment_type_mst VALUES (1, 'Medical management', 'Y');
INSERT INTO healspan.treatment_type_mst VALUES (2, 'Surgical management', 'Y');


--
-- TOC entry 4866 (class 0 OID 49532)
-- Dependencies: 388
-- Data for Name: user_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.user_mst VALUES (1, NULL, 'System', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'System', NULL, 1);
INSERT INTO healspan.user_mst VALUES (2, NULL, 'Hospital-1', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'Hospital-1', 1, 2);
INSERT INTO healspan.user_mst VALUES (6, NULL, 'Reviewer-2', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'Reviewer-2', NULL, 3);
INSERT INTO healspan.user_mst VALUES (5, NULL, 'Reviewer-1', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'Reviewer-1', NULL, 3);
INSERT INTO healspan.user_mst VALUES (7, NULL, 'Reviewer-3', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'Reviewer-3', NULL, 3);
INSERT INTO healspan.user_mst VALUES (8, NULL, 'TPA-1', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'TPA-1', NULL, 5);
INSERT INTO healspan.user_mst VALUES (3, NULL, 'Hospital-2', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'Hospital-2', 2, 2);
INSERT INTO healspan.user_mst VALUES (4, NULL, 'Hospital-3', true, NULL, NULL, NULL, 'hqpAaiEzF9RNcuEYqBSVcw==', 'Avis', 3, 2);


--
-- TOC entry 4872 (class 0 OID 54827)
-- Dependencies: 396
-- Data for Name: user_notification; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4868 (class 0 OID 49541)
-- Dependencies: 390
-- Data for Name: user_role_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.user_role_mst VALUES (1, 'Admin', 'Y');
INSERT INTO healspan.user_role_mst VALUES (2, 'Hospital', 'Y');
INSERT INTO healspan.user_role_mst VALUES (3, 'Healspan', 'Y');
INSERT INTO healspan.user_role_mst VALUES (4, 'Courier', 'Y');
INSERT INTO healspan.user_role_mst VALUES (5, 'TPA', 'Y');


--
-- TOC entry 4889 (class 0 OID 112336)
-- Dependencies: 416
-- Data for Name: v_doclist; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.v_doclist VALUES (NULL);


--
-- TOC entry 4890 (class 0 OID 133425)
-- Dependencies: 417
-- Data for Name: v_hospital_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.v_hospital_mst VALUES ('{"hospital_mst" : [{"name" : "Fortiz", "hospitalCode" : "FTZ03", "about" : "Fortis Healthcare Limited – an IHH Healthcare Berhad Company – is a leading integrated healthcare services provider in India. It is one of the largest healthcare organisations in the country with 36 healthcare facilities (including projects under Prodelopment), 4000 operational beds and over 400 diagnostics centres (including JVs). Fortis is present in India, United Arab Emirates (UAE) & Sri Lanka. The Company is listed on the BSE Ltd and National Stock Exchange (NSE) of India. It draws strength from its partnership with global major and parent company, IHH, to build upon its culture of world-class patient care and superlative clinical excellence. Fortis employs 23,000 people (including SRL) who share its vision of becoming the world’s most trusted healthcare network. Fortis offers a full spectrum of integrated healthcare services ranging from clinics to quaternary care facilities and a wide range of ancillary services.", "address" : "Fortis Healthcare Limited, Corporate Office, Tower A, Unitech Business Park, Block – F, 3rd Floor, South City 1, Sector – 41, Gurgaon, Haryana- 122001", "boardLineNumber" : "022 6285 7001", "gstNum" : "27AABCF3718N1ZE", "hospitalId" : "9854565421552", "emailId" : "info@fortishealthcare.com"}, {"name" : "Fortiz", "hospitalCode" : "FTZ03", "about" : "Fortis Healthcare Limited – an IHH Healthcare Berhad Company – is a leading integrated healthcare services provider in India. It is one of the largest healthcare organisations in the country with 36 healthcare facilities (including projects under Prodelopment), 4000 operational beds and over 400 diagnostics centres (including JVs). Fortis is present in India, United Arab Emirates (UAE) & Sri Lanka. The Company is listed on the BSE Ltd and National Stock Exchange (NSE) of India. It draws strength from its partnership with global major and parent company, IHH, to build upon its culture of world-class patient care and superlative clinical excellence. Fortis employs 23,000 people (including SRL) who share its vision of becoming the world’s most trusted healthcare network. Fortis offers a full spectrum of integrated healthcare services ranging from clinics to quaternary care facilities and a wide range of ancillary services.", "address" : "Fortis Healthcare Limited, Corporate Office, Tower A, Unitech Business Park, Block – F, 3rd Floor, South City 1, Sector – 41, Gurgaon, Haryana- 122001", "boardLineNumber" : "022 6285 7001", "gstNum" : "27AABCF3718N1ZE", "hospitalId" : "9854565421552", "emailId" : "info@fortishealthcare.com"}]}');


--
-- TOC entry 4888 (class 0 OID 111517)
-- Dependencies: 415
-- Data for Name: v_tpa_mst; Type: TABLE DATA; Schema: healspan; Owner: root
--

INSERT INTO healspan.v_tpa_mst VALUES ('{"tpa_mst" : [{"id" : 2, "name" : "Medi Assist Insurance TPA Private Limited", "code" : "MAIPL"}, {"id" : 6, "name" : "Family Health Plan Insurance TPA Limited", "code" : "FHPL"}]}');


--
-- TOC entry 4887 (class 0 OID 110117)
-- Dependencies: 414
-- Data for Name: v_tpa_response; Type: TABLE DATA; Schema: healspan; Owner: root
--



--
-- TOC entry 4933 (class 0 OID 0)
-- Dependencies: 403
-- Name: app_error_log_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.app_error_log_id_seq', 1, false);


--
-- TOC entry 4934 (class 0 OID 0)
-- Dependencies: 337
-- Name: chronic_illness_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.chronic_illness_mst_id_seq', 5, true);


--
-- TOC entry 4935 (class 0 OID 0)
-- Dependencies: 339
-- Name: claim_assignment_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.claim_assignment_id_seq', 536, true);


--
-- TOC entry 4936 (class 0 OID 0)
-- Dependencies: 341
-- Name: claim_info_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.claim_info_id_seq', 115, true);


--
-- TOC entry 4937 (class 0 OID 0)
-- Dependencies: 343
-- Name: claim_stage_link_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.claim_stage_link_id_seq', 136, true);


--
-- TOC entry 4938 (class 0 OID 0)
-- Dependencies: 345
-- Name: claim_stage_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.claim_stage_mst_id_seq', 4, true);


--
-- TOC entry 4939 (class 0 OID 0)
-- Dependencies: 397
-- Name: contact_type_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.contact_type_id_seq', 2, true);


--
-- TOC entry 4940 (class 0 OID 0)
-- Dependencies: 347
-- Name: diagnosis_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.diagnosis_mst_id_seq', 57, true);


--
-- TOC entry 4941 (class 0 OID 0)
-- Dependencies: 349
-- Name: document_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.document_id_seq', 562, true);


--
-- TOC entry 4942 (class 0 OID 0)
-- Dependencies: 351
-- Name: document_type_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.document_type_mst_id_seq', 4, true);


--
-- TOC entry 4943 (class 0 OID 0)
-- Dependencies: 408
-- Name: gender_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.gender_mst_id_seq', 6, true);


--
-- TOC entry 4944 (class 0 OID 0)
-- Dependencies: 353
-- Name: hospital_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.hospital_mst_id_seq', 5, true);


--
-- TOC entry 4945 (class 0 OID 0)
-- Dependencies: 355
-- Name: insurance_company_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.insurance_company_mst_id_seq', 32, true);


--
-- TOC entry 4946 (class 0 OID 0)
-- Dependencies: 357
-- Name: insurance_info_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.insurance_info_id_seq', 156, true);


--
-- TOC entry 4947 (class 0 OID 0)
-- Dependencies: 359
-- Name: mandatory_documents_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.mandatory_documents_mst_id_seq', 17, true);


--
-- TOC entry 4948 (class 0 OID 0)
-- Dependencies: 399
-- Name: max_hospital_claim_id_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.max_hospital_claim_id_id_seq', 14, true);


--
-- TOC entry 4949 (class 0 OID 0)
-- Dependencies: 361
-- Name: medical_chronic_illness_link_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.medical_chronic_illness_link_id_seq', 602, true);


--
-- TOC entry 4950 (class 0 OID 0)
-- Dependencies: 363
-- Name: medical_info_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.medical_info_id_seq', 130, true);


--
-- TOC entry 4951 (class 0 OID 0)
-- Dependencies: 393
-- Name: notification_config_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.notification_config_id_seq', 27, true);


--
-- TOC entry 4952 (class 0 OID 0)
-- Dependencies: 365
-- Name: other_costs_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.other_costs_mst_id_seq', 8, true);


--
-- TOC entry 4953 (class 0 OID 0)
-- Dependencies: 367
-- Name: patient_info_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.patient_info_id_seq', 151, true);


--
-- TOC entry 4954 (class 0 OID 0)
-- Dependencies: 369
-- Name: patient_othercost_link_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.patient_othercost_link_id_seq', 178, true);


--
-- TOC entry 4955 (class 0 OID 0)
-- Dependencies: 371
-- Name: procedure_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.procedure_mst_id_seq', 57, true);


--
-- TOC entry 4956 (class 0 OID 0)
-- Dependencies: 373
-- Name: question_answer_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.question_answer_id_seq', 24, true);


--
-- TOC entry 4957 (class 0 OID 0)
-- Dependencies: 410
-- Name: relationship_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.relationship_mst_id_seq', 52, true);


--
-- TOC entry 4958 (class 0 OID 0)
-- Dependencies: 412
-- Name: room_category_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.room_category_mst_id_seq', 33, true);


--
-- TOC entry 4959 (class 0 OID 0)
-- Dependencies: 375
-- Name: sla_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.sla_mst_id_seq', 1, true);


--
-- TOC entry 4960 (class 0 OID 0)
-- Dependencies: 377
-- Name: speciality_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.speciality_mst_id_seq', 10, true);


--
-- TOC entry 4961 (class 0 OID 0)
-- Dependencies: 379
-- Name: stage_and_document_link_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.stage_and_document_link_mst_id_seq', 30, true);


--
-- TOC entry 4962 (class 0 OID 0)
-- Dependencies: 381
-- Name: status_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.status_mst_id_seq', 27, true);


--
-- TOC entry 4963 (class 0 OID 0)
-- Dependencies: 383
-- Name: tpa_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.tpa_mst_id_seq', 20, true);


--
-- TOC entry 4964 (class 0 OID 0)
-- Dependencies: 401
-- Name: tpa_update_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.tpa_update_id_seq', 68, true);


--
-- TOC entry 4965 (class 0 OID 0)
-- Dependencies: 385
-- Name: treatment_type_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.treatment_type_mst_id_seq', 2, true);


--
-- TOC entry 4966 (class 0 OID 0)
-- Dependencies: 387
-- Name: user_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.user_mst_id_seq', 10, true);


--
-- TOC entry 4967 (class 0 OID 0)
-- Dependencies: 395
-- Name: user_notification_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.user_notification_id_seq', 503, true);


--
-- TOC entry 4968 (class 0 OID 0)
-- Dependencies: 389
-- Name: user_role_mst_id_seq; Type: SEQUENCE SET; Schema: healspan; Owner: root
--

SELECT pg_catalog.setval('healspan.user_role_mst_id_seq', 5, true);


--
-- TOC entry 4620 (class 2606 OID 87403)
-- Name: app_error_log app_error_log_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.app_error_log
    ADD CONSTRAINT app_error_log_pkey PRIMARY KEY (id);


--
-- TOC entry 4558 (class 2606 OID 49314)
-- Name: chronic_illness_mst chronic_illness_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.chronic_illness_mst
    ADD CONSTRAINT chronic_illness_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4560 (class 2606 OID 49323)
-- Name: claim_assignment claim_assignment_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT claim_assignment_pkey PRIMARY KEY (id);


--
-- TOC entry 4562 (class 2606 OID 49330)
-- Name: claim_info claim_info_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_info
    ADD CONSTRAINT claim_info_pkey PRIMARY KEY (id);


--
-- TOC entry 4564 (class 2606 OID 49337)
-- Name: claim_stage_link claim_stage_link_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT claim_stage_link_pkey PRIMARY KEY (id);


--
-- TOC entry 4566 (class 2606 OID 49344)
-- Name: claim_stage_mst claim_stage_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_mst
    ADD CONSTRAINT claim_stage_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4616 (class 2606 OID 66382)
-- Name: contact_type contact_type_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.contact_type
    ADD CONSTRAINT contact_type_pkey PRIMARY KEY (id);


--
-- TOC entry 4568 (class 2606 OID 49353)
-- Name: diagnosis_mst diagnosis_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.diagnosis_mst
    ADD CONSTRAINT diagnosis_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4570 (class 2606 OID 49362)
-- Name: document document_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.document
    ADD CONSTRAINT document_pkey PRIMARY KEY (id);


--
-- TOC entry 4572 (class 2606 OID 49369)
-- Name: document_type_mst document_type_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.document_type_mst
    ADD CONSTRAINT document_type_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4622 (class 2606 OID 107078)
-- Name: gender_mst gender_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.gender_mst
    ADD CONSTRAINT gender_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4574 (class 2606 OID 49385)
-- Name: hospital_mst hospital_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.hospital_mst
    ADD CONSTRAINT hospital_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4576 (class 2606 OID 49392)
-- Name: insurance_company_mst insurance_company_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_company_mst
    ADD CONSTRAINT insurance_company_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4578 (class 2606 OID 49401)
-- Name: insurance_info insurance_info_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_info
    ADD CONSTRAINT insurance_info_pkey PRIMARY KEY (id);


--
-- TOC entry 4580 (class 2606 OID 49408)
-- Name: mandatory_documents_mst mandatory_documents_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.mandatory_documents_mst
    ADD CONSTRAINT mandatory_documents_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4582 (class 2606 OID 49415)
-- Name: medical_chronic_illness_link medical_chronic_illness_link_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_chronic_illness_link
    ADD CONSTRAINT medical_chronic_illness_link_pkey PRIMARY KEY (id);


--
-- TOC entry 4584 (class 2606 OID 49424)
-- Name: medical_info medical_info_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_info
    ADD CONSTRAINT medical_info_pkey PRIMARY KEY (id);


--
-- TOC entry 4612 (class 2606 OID 81090)
-- Name: notification_config notification_config_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.notification_config
    ADD CONSTRAINT notification_config_pkey PRIMARY KEY (id);


--
-- TOC entry 4586 (class 2606 OID 49431)
-- Name: other_costs_mst other_costs_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.other_costs_mst
    ADD CONSTRAINT other_costs_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4588 (class 2606 OID 49440)
-- Name: patient_info patient_info_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_info
    ADD CONSTRAINT patient_info_pkey PRIMARY KEY (id);


--
-- TOC entry 4590 (class 2606 OID 49447)
-- Name: patient_othercost_link patient_othercost_link_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_othercost_link
    ADD CONSTRAINT patient_othercost_link_pkey PRIMARY KEY (id);


--
-- TOC entry 4592 (class 2606 OID 49456)
-- Name: procedure_mst procedure_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.procedure_mst
    ADD CONSTRAINT procedure_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4594 (class 2606 OID 49465)
-- Name: question_answer question_answer_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.question_answer
    ADD CONSTRAINT question_answer_pkey PRIMARY KEY (id);


--
-- TOC entry 4624 (class 2606 OID 107085)
-- Name: relationship_mst relationship_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.relationship_mst
    ADD CONSTRAINT relationship_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4626 (class 2606 OID 107133)
-- Name: room_category_mst room_category_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.room_category_mst
    ADD CONSTRAINT room_category_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4596 (class 2606 OID 49486)
-- Name: sla_mst sla_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.sla_mst
    ADD CONSTRAINT sla_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4598 (class 2606 OID 49493)
-- Name: speciality_mst speciality_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.speciality_mst
    ADD CONSTRAINT speciality_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4600 (class 2606 OID 49500)
-- Name: stage_and_document_link_mst stage_and_document_link_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.stage_and_document_link_mst
    ADD CONSTRAINT stage_and_document_link_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4602 (class 2606 OID 49507)
-- Name: status_mst status_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.status_mst
    ADD CONSTRAINT status_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4604 (class 2606 OID 49514)
-- Name: tpa_mst tpa_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_mst
    ADD CONSTRAINT tpa_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4618 (class 2606 OID 78335)
-- Name: tpa_update tpa_update_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_update
    ADD CONSTRAINT tpa_update_pkey PRIMARY KEY (id);


--
-- TOC entry 4606 (class 2606 OID 49530)
-- Name: treatment_type_mst treatment_type_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.treatment_type_mst
    ADD CONSTRAINT treatment_type_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4608 (class 2606 OID 49539)
-- Name: user_mst user_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_mst
    ADD CONSTRAINT user_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4614 (class 2606 OID 81072)
-- Name: user_notification user_notification_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_notification
    ADD CONSTRAINT user_notification_pkey PRIMARY KEY (id);


--
-- TOC entry 4610 (class 2606 OID 49546)
-- Name: user_role_mst user_role_mst_pkey; Type: CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_role_mst
    ADD CONSTRAINT user_role_mst_pkey PRIMARY KEY (id);


--
-- TOC entry 4652 (class 2606 OID 49672)
-- Name: medical_info fk1reelpd9u4dj4xdc7fsf1mo5l; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_info
    ADD CONSTRAINT fk1reelpd9u4dj4xdc7fsf1mo5l FOREIGN KEY (speciality_mst_id) REFERENCES healspan.speciality_mst(id);


--
-- TOC entry 4654 (class 2606 OID 49687)
-- Name: patient_info fk31xa9k3yh4uo40ri9oj4yom8q; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_info
    ADD CONSTRAINT fk31xa9k3yh4uo40ri9oj4yom8q FOREIGN KEY (hospital_mst_id) REFERENCES healspan.hospital_mst(id);


--
-- TOC entry 4662 (class 2606 OID 49722)
-- Name: stage_and_document_link_mst fk3bivrtfhkuk0gxngcolfksdju; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.stage_and_document_link_mst
    ADD CONSTRAINT fk3bivrtfhkuk0gxngcolfksdju FOREIGN KEY (mandatory_documents_mst_id) REFERENCES healspan.mandatory_documents_mst(id);


--
-- TOC entry 4639 (class 2606 OID 49607)
-- Name: claim_stage_link fk4a3bolyyfie6cbs5yyo6mfgau; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fk4a3bolyyfie6cbs5yyo6mfgau FOREIGN KEY (patient_info_id) REFERENCES healspan.patient_info(id);


--
-- TOC entry 4668 (class 2606 OID 78336)
-- Name: tpa_update fk4lu7rwa94qu0fg8ucx5igwhb8; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_update
    ADD CONSTRAINT fk4lu7rwa94qu0fg8ucx5igwhb8 FOREIGN KEY (claim_stage_link_id) REFERENCES healspan.claim_stage_link(id);


--
-- TOC entry 4669 (class 2606 OID 78341)
-- Name: tpa_update fk55s9wr33k8daui0nh9l9c2gau; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_update
    ADD CONSTRAINT fk55s9wr33k8daui0nh9l9c2gau FOREIGN KEY (claim_stage_id) REFERENCES healspan.claim_stage_mst(id);


--
-- TOC entry 4644 (class 2606 OID 49632)
-- Name: document fk5f8yx7sdhp1795p7hcdpphg12; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.document
    ADD CONSTRAINT fk5f8yx7sdhp1795p7hcdpphg12 FOREIGN KEY (mandatory_documents_mst_id) REFERENCES healspan.mandatory_documents_mst(id);


--
-- TOC entry 4648 (class 2606 OID 49652)
-- Name: medical_chronic_illness_link fk5xupi3ts9korv9ynmokml89qn; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_chronic_illness_link
    ADD CONSTRAINT fk5xupi3ts9korv9ynmokml89qn FOREIGN KEY (chronic_illness_mst_id) REFERENCES healspan.chronic_illness_mst(id);


--
-- TOC entry 4643 (class 2606 OID 49627)
-- Name: document fk6eu9y5k7tbp30vfxq363hfvfj; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.document
    ADD CONSTRAINT fk6eu9y5k7tbp30vfxq363hfvfj FOREIGN KEY (claim_stage_link_id) REFERENCES healspan.claim_stage_link(id);


--
-- TOC entry 4655 (class 2606 OID 107103)
-- Name: patient_info fk78prxrdgisdhxpx6sr4c0g1jp; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_info
    ADD CONSTRAINT fk78prxrdgisdhxpx6sr4c0g1jp FOREIGN KEY (gender_mst_id) REFERENCES healspan.gender_mst(id);


--
-- TOC entry 4633 (class 2606 OID 49577)
-- Name: claim_info fk7p9on31ek2wccogv142huqsc9; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_info
    ADD CONSTRAINT fk7p9on31ek2wccogv142huqsc9 FOREIGN KEY (hospital_mst_id) REFERENCES healspan.hospital_mst(id);


--
-- TOC entry 4658 (class 2606 OID 49702)
-- Name: patient_othercost_link fk7umk4i64ivg1ojh6ljs2w4drd; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_othercost_link
    ADD CONSTRAINT fk7umk4i64ivg1ojh6ljs2w4drd FOREIGN KEY (patient_info_id) REFERENCES healspan.patient_info(id);


--
-- TOC entry 4660 (class 2606 OID 49712)
-- Name: question_answer fk817slcvwh9wattfhrof40q4mr; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.question_answer
    ADD CONSTRAINT fk817slcvwh9wattfhrof40q4mr FOREIGN KEY (claim_stage_link_id) REFERENCES healspan.claim_stage_link(id);


--
-- TOC entry 4637 (class 2606 OID 49597)
-- Name: claim_stage_link fk82tvqym5yvba5mxk41pk3a4i4; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fk82tvqym5yvba5mxk41pk3a4i4 FOREIGN KEY (insurance_info_id) REFERENCES healspan.insurance_info(id);


--
-- TOC entry 4642 (class 2606 OID 49622)
-- Name: diagnosis_mst fk87xchoyhlep5ngtdegjfdkntw; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.diagnosis_mst
    ADD CONSTRAINT fk87xchoyhlep5ngtdegjfdkntw FOREIGN KEY (tpa_mst_id) REFERENCES healspan.tpa_mst(id);


--
-- TOC entry 4645 (class 2606 OID 49637)
-- Name: insurance_info fk8d3hqm78vbdmvx1q3mh99hdh8; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_info
    ADD CONSTRAINT fk8d3hqm78vbdmvx1q3mh99hdh8 FOREIGN KEY (insurance_company_mst_id) REFERENCES healspan.insurance_company_mst(id);


--
-- TOC entry 4646 (class 2606 OID 49647)
-- Name: insurance_info fkagmv1479jq8x9kb1c4r7uc4xw; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_info
    ADD CONSTRAINT fkagmv1479jq8x9kb1c4r7uc4xw FOREIGN KEY (tpa_mst_id) REFERENCES healspan.tpa_mst(id);


--
-- TOC entry 4667 (class 2606 OID 132047)
-- Name: contact_type fkauv6ksewhv317jkmtjpou8hej; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.contact_type
    ADD CONSTRAINT fkauv6ksewhv317jkmtjpou8hej FOREIGN KEY (hospital_mst_id) REFERENCES healspan.hospital_mst(id);


--
-- TOC entry 4631 (class 2606 OID 49567)
-- Name: claim_assignment fkbjror89p49jbwpfmgrol7k3r6; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT fkbjror89p49jbwpfmgrol7k3r6 FOREIGN KEY (status_mst_id) REFERENCES healspan.status_mst(id);


--
-- TOC entry 4657 (class 2606 OID 49697)
-- Name: patient_othercost_link fkbvmbo5ik7vg7vmsep25rp75om; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_othercost_link
    ADD CONSTRAINT fkbvmbo5ik7vg7vmsep25rp75om FOREIGN KEY (other_costs_mst_id) REFERENCES healspan.other_costs_mst(id);


--
-- TOC entry 4673 (class 2606 OID 107139)
-- Name: room_category_mst fkbw1i6fbqdfpv7b40a8pq2u319; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.room_category_mst
    ADD CONSTRAINT fkbw1i6fbqdfpv7b40a8pq2u319 FOREIGN KEY (tpa_mst_id) REFERENCES healspan.tpa_mst(id);


--
-- TOC entry 4672 (class 2606 OID 107113)
-- Name: relationship_mst fkc0cmey5qyg2iicgutr1q7rnbs; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.relationship_mst
    ADD CONSTRAINT fkc0cmey5qyg2iicgutr1q7rnbs FOREIGN KEY (tpa_mst_id) REFERENCES healspan.tpa_mst(id);


--
-- TOC entry 4630 (class 2606 OID 49562)
-- Name: claim_assignment fkccr68ces9d38utpw4tyrvj4gq; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT fkccr68ces9d38utpw4tyrvj4gq FOREIGN KEY (claim_stage_mst_id) REFERENCES healspan.claim_stage_mst(id);


--
-- TOC entry 4650 (class 2606 OID 49662)
-- Name: medical_info fkceylqmb8sjgok34sg81fajxra; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_info
    ADD CONSTRAINT fkceylqmb8sjgok34sg81fajxra FOREIGN KEY (diagnosis_mst_id) REFERENCES healspan.diagnosis_mst(id);


--
-- TOC entry 4666 (class 2606 OID 49752)
-- Name: user_mst fke49u0iellvdc4r5idvllyuhsm; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_mst
    ADD CONSTRAINT fke49u0iellvdc4r5idvllyuhsm FOREIGN KEY (user_role_mst_id) REFERENCES healspan.user_role_mst(id);


--
-- TOC entry 4638 (class 2606 OID 49602)
-- Name: claim_stage_link fkea5i40j67jpgrpd7qh3hxlgar; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fkea5i40j67jpgrpd7qh3hxlgar FOREIGN KEY (medical_info_id) REFERENCES healspan.medical_info(id);


--
-- TOC entry 4665 (class 2606 OID 49747)
-- Name: user_mst fkf1nbgg4qrycwgt4rubi49yi75; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.user_mst
    ADD CONSTRAINT fkf1nbgg4qrycwgt4rubi49yi75 FOREIGN KEY (hospital_mst_id) REFERENCES healspan.hospital_mst(id);


--
-- TOC entry 4651 (class 2606 OID 49667)
-- Name: medical_info fkg7lod6ygw0cq36p1viypie3y7; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_info
    ADD CONSTRAINT fkg7lod6ygw0cq36p1viypie3y7 FOREIGN KEY (procedure_mst_id) REFERENCES healspan.procedure_mst(id);


--
-- TOC entry 4649 (class 2606 OID 49657)
-- Name: medical_chronic_illness_link fkhoxc5bo3sf5fxi5tq2g6omeo0; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_chronic_illness_link
    ADD CONSTRAINT fkhoxc5bo3sf5fxi5tq2g6omeo0 FOREIGN KEY (medical_info_id) REFERENCES healspan.medical_info(id);


--
-- TOC entry 4659 (class 2606 OID 49707)
-- Name: procedure_mst fkhqwmp2a6jjlhvn2gm06kv0fy2; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.procedure_mst
    ADD CONSTRAINT fkhqwmp2a6jjlhvn2gm06kv0fy2 FOREIGN KEY (tpa_mst_id) REFERENCES healspan.tpa_mst(id);


--
-- TOC entry 4632 (class 2606 OID 49572)
-- Name: claim_assignment fkil7qkbivrsqt1jgt0tdh2srum; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT fkil7qkbivrsqt1jgt0tdh2srum FOREIGN KEY (user_mst_id) REFERENCES healspan.user_mst(id);


--
-- TOC entry 4664 (class 2606 OID 50115)
-- Name: status_mst fkitqg5rhs12o0wwm5tsv7xexpw; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.status_mst
    ADD CONSTRAINT fkitqg5rhs12o0wwm5tsv7xexpw FOREIGN KEY (user_role_mst_id) REFERENCES healspan.user_role_mst(id);


--
-- TOC entry 4656 (class 2606 OID 107134)
-- Name: patient_info fkjw2ctletawjhidq8kvs14giru; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.patient_info
    ADD CONSTRAINT fkjw2ctletawjhidq8kvs14giru FOREIGN KEY (room_category_mst_id) REFERENCES healspan.room_category_mst(id);


--
-- TOC entry 4653 (class 2606 OID 49677)
-- Name: medical_info fkjyf88swsgxv0lnja0kiopg1j2; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.medical_info
    ADD CONSTRAINT fkjyf88swsgxv0lnja0kiopg1j2 FOREIGN KEY (treatment_type_mst_id) REFERENCES healspan.treatment_type_mst(id);


--
-- TOC entry 4640 (class 2606 OID 49612)
-- Name: claim_stage_link fkk83ncxh639txscbg8hu4bkg21; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fkk83ncxh639txscbg8hu4bkg21 FOREIGN KEY (status_mst_id) REFERENCES healspan.status_mst(id);


--
-- TOC entry 4647 (class 2606 OID 107098)
-- Name: insurance_info fklexjnv8rg6xngmypr8nqccu5b; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.insurance_info
    ADD CONSTRAINT fklexjnv8rg6xngmypr8nqccu5b FOREIGN KEY (relationship_mst_id) REFERENCES healspan.relationship_mst(id);


--
-- TOC entry 4661 (class 2606 OID 49717)
-- Name: stage_and_document_link_mst fknc8u01p07il9fy61cd9kngb4o; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.stage_and_document_link_mst
    ADD CONSTRAINT fknc8u01p07il9fy61cd9kngb4o FOREIGN KEY (claim_stage_mst_id) REFERENCES healspan.claim_stage_mst(id);


--
-- TOC entry 4629 (class 2606 OID 49557)
-- Name: claim_assignment fknlgpoctjsshr7ghasc0hrglt4; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT fknlgpoctjsshr7ghasc0hrglt4 FOREIGN KEY (claim_stage_link_id) REFERENCES healspan.claim_stage_link(id);


--
-- TOC entry 4671 (class 2606 OID 107093)
-- Name: gender_mst fknu6a09a6qgi2x1rt929x3nqnd; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.gender_mst
    ADD CONSTRAINT fknu6a09a6qgi2x1rt929x3nqnd FOREIGN KEY (tpa_mst_id) REFERENCES healspan.tpa_mst(id);


--
-- TOC entry 4641 (class 2606 OID 49617)
-- Name: claim_stage_link fknvi2ifr0f74gpwsx4ro6r0emm; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fknvi2ifr0f74gpwsx4ro6r0emm FOREIGN KEY (user_mst_id) REFERENCES healspan.user_mst(id);


--
-- TOC entry 4628 (class 2606 OID 49552)
-- Name: claim_assignment fko5lp2vvw4xuqls712jc7vuk7w; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT fko5lp2vvw4xuqls712jc7vuk7w FOREIGN KEY (claim_info_id) REFERENCES healspan.claim_info(id);


--
-- TOC entry 4634 (class 2606 OID 49582)
-- Name: claim_info fkonb8etyoi65haifwysk4fqsc8; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_info
    ADD CONSTRAINT fkonb8etyoi65haifwysk4fqsc8 FOREIGN KEY (user_mst_id) REFERENCES healspan.user_mst(id);


--
-- TOC entry 4663 (class 2606 OID 49727)
-- Name: status_mst fkpfe88mi48cijsytumi2wmsmqj; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.status_mst
    ADD CONSTRAINT fkpfe88mi48cijsytumi2wmsmqj FOREIGN KEY (claim_stage_id) REFERENCES healspan.claim_stage_mst(id);


--
-- TOC entry 4635 (class 2606 OID 49587)
-- Name: claim_stage_link fkrjryrvgimwg1h5ww78me4r3o6; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fkrjryrvgimwg1h5ww78me4r3o6 FOREIGN KEY (claim_info_id) REFERENCES healspan.claim_info(id);


--
-- TOC entry 4636 (class 2606 OID 49592)
-- Name: claim_stage_link fkt7k2qryj5kp6s9uhswq94rap2; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_stage_link
    ADD CONSTRAINT fkt7k2qryj5kp6s9uhswq94rap2 FOREIGN KEY (claim_stage_mst_id) REFERENCES healspan.claim_stage_mst(id);


--
-- TOC entry 4627 (class 2606 OID 49547)
-- Name: claim_assignment fkte00arciicosibpac2ut8pm5j; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.claim_assignment
    ADD CONSTRAINT fkte00arciicosibpac2ut8pm5j FOREIGN KEY (assigned_to_user_role_mst_id) REFERENCES healspan.user_role_mst(id);


--
-- TOC entry 4670 (class 2606 OID 78346)
-- Name: tpa_update fky0fbsv9nbrur385pw8pglsqw; Type: FK CONSTRAINT; Schema: healspan; Owner: root
--

ALTER TABLE ONLY healspan.tpa_update
    ADD CONSTRAINT fky0fbsv9nbrur385pw8pglsqw FOREIGN KEY (claim_info_id) REFERENCES healspan.claim_info(id);


-- Completed on 2023-03-08 12:02:34

--
-- PostgreSQL database dump complete
--

