-- FHIR ASSESSMENT - CONSOLIDATED SQL REFERENCE



====================================================================
-- 01_Schemas_and_Tables.sql
====================================================================

-- FHIR assessment: reconstructed DDL. Run on a new database only after reviewing against existing objects.
IF SCHEMA_ID('staging') IS NULL EXEC('CREATE SCHEMA staging');
IF SCHEMA_ID('silver') IS NULL EXEC('CREATE SCHEMA silver');
IF SCHEMA_ID('control') IS NULL EXEC('CREATE SCHEMA control');
GO
IF OBJECT_ID('staging.fhir_raw','U') IS NULL
CREATE TABLE staging.fhir_raw (
 staging_id BIGINT IDENTITY(1,1) PRIMARY KEY,
 resource_type VARCHAR(50) NOT NULL,
 raw_json NVARCHAR(MAX) NOT NULL,
 extraction_timestamp DATETIME2 DEFAULT SYSUTCDATETIME(),
 api_url_or_params NVARCHAR(2000), source_file NVARCHAR(1000), pipeline_run_id VARCHAR(100)
);
GO
IF OBJECT_ID('silver.Patient','U') IS NULL
CREATE TABLE silver.Patient (
 patient_id NVARCHAR(100) PRIMARY KEY, family_name NVARCHAR(200), given_name NVARCHAR(200),
 gender NVARCHAR(20), birth_date DATE, last_updated DATETIME2
);
IF OBJECT_ID('silver.Encounter','U') IS NULL
CREATE TABLE silver.Encounter (
 encounter_id NVARCHAR(100) PRIMARY KEY, patient_id NVARCHAR(100), status NVARCHAR(100),
 encounter_class NVARCHAR(100), start_date DATETIME2, end_date DATETIME2, last_updated DATETIME2
);
IF OBJECT_ID('silver.Observation','U') IS NULL
CREATE TABLE silver.Observation (
 observation_id NVARCHAR(100) PRIMARY KEY, patient_id NVARCHAR(100), encounter_id NVARCHAR(100),
 status NVARCHAR(100), observation_code NVARCHAR(200), observation_name NVARCHAR(1000),
 observation_value NVARCHAR(500), observation_unit NVARCHAR(200), effective_date DATETIME2,
 last_updated DATETIME2
);
IF OBJECT_ID('silver.Condition','U') IS NULL
CREATE TABLE silver.Condition (
 condition_id NVARCHAR(100) PRIMARY KEY, patient_id NVARCHAR(100), encounter_id NVARCHAR(100),
 clinical_status NVARCHAR(100), condition_code NVARCHAR(200), condition_name NVARCHAR(1000),
 onset_date DATETIME2, recorded_date DATETIME2, last_updated DATETIME2
);
IF OBJECT_ID('silver.Patient_History','U') IS NULL
CREATE TABLE silver.Patient_History (
 history_id BIGINT IDENTITY(1,1) PRIMARY KEY, patient_id NVARCHAR(100) NOT NULL,
 family_name NVARCHAR(200), given_name NVARCHAR(200), gender NVARCHAR(20), birth_date DATE,
 effective_from DATETIME2 NOT NULL, effective_to DATETIME2 NULL, is_current BIT NOT NULL
);
IF OBJECT_ID('control.fhir_watermark','U') IS NULL
CREATE TABLE control.fhir_watermark (
 resource_type VARCHAR(50) PRIMARY KEY, last_updated DATETIME2 NULL, last_run_time DATETIME2 NULL
);
GO
INSERT INTO control.fhir_watermark(resource_type,last_updated,last_run_time)
SELECT x.resource_type,NULL,NULL FROM (VALUES ('Patient'),('Encounter'),('Observation'),('Condition')) x(resource_type)
WHERE NOT EXISTS (SELECT 1 FROM control.fhir_watermark w WHERE w.resource_type=x.resource_type);
GO


====================================================================
-- 02_Staging_Procedure.sql
====================================================================

CREATE OR ALTER PROCEDURE staging.usp_insert_fhir_raw
 @resource_type VARCHAR(50), @raw_json NVARCHAR(MAX),
 @api_url_or_params NVARCHAR(2000)=NULL, @source_file NVARCHAR(1000)=NULL,
 @pipeline_run_id VARCHAR(100)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 IF ISJSON(@raw_json) <> 1 THROW 50001, 'Invalid FHIR JSON', 1;
 INSERT INTO staging.fhir_raw(resource_type,raw_json,api_url_or_params,source_file,pipeline_run_id)
 VALUES (@resource_type,@raw_json,@api_url_or_params,@source_file,@pipeline_run_id);
END;
GO


====================================================================
-- 03_Silver_Upsert_Procedures.sql
====================================================================

-- Each upsert chooses the latest version of each resource ID across staged FHIR Bundles.
CREATE OR ALTER PROCEDURE silver.usp_Upsert_Patient
AS
BEGIN
 SET NOCOUNT ON;
 ;WITH src AS (
  SELECT JSON_VALUE(e.value,'$.resource.id') AS patient_id,
   JSON_VALUE(e.value,'$.resource.name[0].family') AS family_name,
   JSON_VALUE(e.value,'$.resource.name[0].given[0]') AS given_name,
   JSON_VALUE(e.value,'$.resource.gender') AS gender,
   TRY_CONVERT(DATE,JSON_VALUE(e.value,'$.resource.birthDate')) AS birth_date,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) AS last_updated,
   ROW_NUMBER() OVER(PARTITION BY JSON_VALUE(e.value,'$.resource.id')
    ORDER BY TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) DESC,r.staging_id DESC) AS rn
  FROM staging.fhir_raw r CROSS APPLY OPENJSON(r.raw_json,'$.entry') e
  WHERE r.resource_type='Patient'
 )
 MERGE silver.Patient AS t
 USING (SELECT * FROM src WHERE rn=1 AND patient_id IS NOT NULL) AS s ON t.patient_id=s.patient_id
 WHEN MATCHED AND EXISTS (SELECT s.family_name,s.given_name,s.gender,s.birth_date,s.last_updated
                          EXCEPT SELECT t.family_name,t.given_name,t.gender,t.birth_date,t.last_updated)
 THEN UPDATE SET family_name=s.family_name,given_name=s.given_name,gender=s.gender,
                 birth_date=s.birth_date,last_updated=s.last_updated
 WHEN NOT MATCHED THEN INSERT(patient_id,family_name,given_name,gender,birth_date,last_updated)
 VALUES(s.patient_id,s.family_name,s.given_name,s.gender,s.birth_date,s.last_updated);
END;
GO
CREATE OR ALTER PROCEDURE silver.usp_Upsert_Encounter
AS
BEGIN
 SET NOCOUNT ON;
 ;WITH src AS (
  SELECT JSON_VALUE(e.value,'$.resource.id') AS encounter_id,
   REPLACE(JSON_VALUE(e.value,'$.resource.subject.reference'),'Patient/','') AS patient_id,
   JSON_VALUE(e.value,'$.resource.status') AS status,
   JSON_VALUE(e.value,'$.resource.class.code') AS encounter_class,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.period.start')) AS start_date,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.period.end')) AS end_date,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) AS last_updated,
   ROW_NUMBER() OVER(PARTITION BY JSON_VALUE(e.value,'$.resource.id')
    ORDER BY TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) DESC,r.staging_id DESC) AS rn
  FROM staging.fhir_raw r CROSS APPLY OPENJSON(r.raw_json,'$.entry') e WHERE r.resource_type='Encounter'
 )
 MERGE silver.Encounter t USING (SELECT * FROM src WHERE rn=1 AND encounter_id IS NOT NULL) s
 ON t.encounter_id=s.encounter_id
 WHEN MATCHED AND EXISTS (SELECT s.patient_id,s.status,s.encounter_class,s.start_date,s.end_date,s.last_updated
                          EXCEPT SELECT t.patient_id,t.status,t.encounter_class,t.start_date,t.end_date,t.last_updated)
 THEN UPDATE SET patient_id=s.patient_id,status=s.status,encounter_class=s.encounter_class,
                 start_date=s.start_date,end_date=s.end_date,last_updated=s.last_updated
 WHEN NOT MATCHED THEN INSERT(encounter_id,patient_id,status,encounter_class,start_date,end_date,last_updated)
 VALUES(s.encounter_id,s.patient_id,s.status,s.encounter_class,s.start_date,s.end_date,s.last_updated);
END;
GO
CREATE OR ALTER PROCEDURE silver.usp_Upsert_Observation
AS
BEGIN
 SET NOCOUNT ON;
 ;WITH src AS (
  SELECT JSON_VALUE(e.value,'$.resource.id') AS observation_id,
   REPLACE(JSON_VALUE(e.value,'$.resource.subject.reference'),'Patient/','') AS patient_id,
   REPLACE(JSON_VALUE(e.value,'$.resource.encounter.reference'),'Encounter/','') AS encounter_id,
   JSON_VALUE(e.value,'$.resource.status') AS status,
   JSON_VALUE(e.value,'$.resource.code.coding[0].code') AS observation_code,
   COALESCE(JSON_VALUE(e.value,'$.resource.code.text'),JSON_VALUE(e.value,'$.resource.code.coding[0].display')) AS observation_name,
   COALESCE(JSON_VALUE(e.value,'$.resource.valueQuantity.value'),JSON_VALUE(e.value,'$.resource.valueString'),
            JSON_VALUE(e.value,'$.resource.valueCodeableConcept.text')) AS observation_value,
   COALESCE(JSON_VALUE(e.value,'$.resource.valueQuantity.unit'),JSON_VALUE(e.value,'$.resource.valueQuantity.code')) AS observation_unit,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.effectiveDateTime')) AS effective_date,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) AS last_updated,
   ROW_NUMBER() OVER(PARTITION BY JSON_VALUE(e.value,'$.resource.id')
    ORDER BY TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) DESC,r.staging_id DESC) AS rn
  FROM staging.fhir_raw r CROSS APPLY OPENJSON(r.raw_json,'$.entry') e WHERE r.resource_type='Observation'
 )
 MERGE silver.Observation t USING (SELECT * FROM src WHERE rn=1 AND observation_id IS NOT NULL) s
 ON t.observation_id=s.observation_id
 WHEN MATCHED AND EXISTS (SELECT s.patient_id,s.encounter_id,s.status,s.observation_code,s.observation_name,
  s.observation_value,s.observation_unit,s.effective_date,s.last_updated
  EXCEPT SELECT t.patient_id,t.encounter_id,t.status,t.observation_code,t.observation_name,
  t.observation_value,t.observation_unit,t.effective_date,t.last_updated)
 THEN UPDATE SET patient_id=s.patient_id,encounter_id=s.encounter_id,status=s.status,
  observation_code=s.observation_code,observation_name=s.observation_name,
  observation_value=s.observation_value,observation_unit=s.observation_unit,
  effective_date=s.effective_date,last_updated=s.last_updated
 WHEN NOT MATCHED THEN INSERT(observation_id,patient_id,encounter_id,status,observation_code,
  observation_name,observation_value,observation_unit,effective_date,last_updated)
 VALUES(s.observation_id,s.patient_id,s.encounter_id,s.status,s.observation_code,
  s.observation_name,s.observation_value,s.observation_unit,s.effective_date,s.last_updated);
END;
GO
CREATE OR ALTER PROCEDURE silver.usp_Upsert_Condition
AS
BEGIN
 SET NOCOUNT ON;
 ;WITH src AS (
  SELECT JSON_VALUE(e.value,'$.resource.id') AS condition_id,
   REPLACE(JSON_VALUE(e.value,'$.resource.subject.reference'),'Patient/','') AS patient_id,
   REPLACE(JSON_VALUE(e.value,'$.resource.encounter.reference'),'Encounter/','') AS encounter_id,
   JSON_VALUE(e.value,'$.resource.clinicalStatus.coding[0].code') AS clinical_status,
   JSON_VALUE(e.value,'$.resource.code.coding[0].code') AS condition_code,
   COALESCE(JSON_VALUE(e.value,'$.resource.code.text'),JSON_VALUE(e.value,'$.resource.code.coding[0].display')) AS condition_name,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.onsetDateTime')) AS onset_date,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.recordedDate')) AS recorded_date,
   TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) AS last_updated,
   ROW_NUMBER() OVER(PARTITION BY JSON_VALUE(e.value,'$.resource.id')
    ORDER BY TRY_CONVERT(DATETIME2,JSON_VALUE(e.value,'$.resource.meta.lastUpdated')) DESC,r.staging_id DESC) AS rn
  FROM staging.fhir_raw r CROSS APPLY OPENJSON(r.raw_json,'$.entry') e WHERE r.resource_type='Condition'
 )
 MERGE silver.Condition t USING (SELECT * FROM src WHERE rn=1 AND condition_id IS NOT NULL) s
 ON t.condition_id=s.condition_id
 WHEN MATCHED AND EXISTS (SELECT s.patient_id,s.encounter_id,s.clinical_status,s.condition_code,s.condition_name,
  s.onset_date,s.recorded_date,s.last_updated
  EXCEPT SELECT t.patient_id,t.encounter_id,t.clinical_status,t.condition_code,t.condition_name,
  t.onset_date,t.recorded_date,t.last_updated)
 THEN UPDATE SET patient_id=s.patient_id,encounter_id=s.encounter_id,clinical_status=s.clinical_status,
  condition_code=s.condition_code,condition_name=s.condition_name,onset_date=s.onset_date,
  recorded_date=s.recorded_date,last_updated=s.last_updated
 WHEN NOT MATCHED THEN INSERT(condition_id,patient_id,encounter_id,clinical_status,condition_code,
  condition_name,onset_date,recorded_date,last_updated)
 VALUES(s.condition_id,s.patient_id,s.encounter_id,s.clinical_status,s.condition_code,
  s.condition_name,s.onset_date,s.recorded_date,s.last_updated);
END;
GO


====================================================================
-- 04_Patient_SCD2.sql
====================================================================

-- Compare current Silver patient attributes with current history and maintain Type 2 versions.
-- This reconstructed implementation uses the processing time as the SCD effective timestamp.
CREATE OR ALTER PROCEDURE silver.usp_Patient_SCD2
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 BEGIN TRANSACTION;
 DECLARE @now DATETIME2 = SYSUTCDATETIME();
 UPDATE h SET effective_to=@now,is_current=0
 FROM silver.Patient_History h
 INNER JOIN silver.Patient p ON p.patient_id=h.patient_id
 WHERE h.is_current=1 AND EXISTS (
  SELECT p.family_name,p.given_name,p.gender,p.birth_date
  EXCEPT SELECT h.family_name,h.given_name,h.gender,h.birth_date
 );
 INSERT INTO silver.Patient_History(patient_id,family_name,given_name,gender,birth_date,effective_from,effective_to,is_current)
 SELECT p.patient_id,p.family_name,p.given_name,p.gender,p.birth_date,@now,NULL,1
 FROM silver.Patient p
 WHERE NOT EXISTS (SELECT 1 FROM silver.Patient_History h WHERE h.patient_id=p.patient_id AND h.is_current=1);
 COMMIT TRANSACTION;
END;
GO


====================================================================
-- 05_Watermark_and_Orchestration.sql
====================================================================

-- Updates watermark from maximum last_updated in the relevant Silver table.
-- WARNING: use only after ALL intended pages have been ingested and processed.
-- A page-limited demo should not advance a production incremental watermark.
CREATE OR ALTER PROCEDURE control.usp_Update_FHIR_Watermark @resource_type VARCHAR(50)
AS
BEGIN
 SET NOCOUNT ON;
 IF @resource_type NOT IN ('Patient','Encounter','Observation','Condition')
  THROW 50002,'Unsupported FHIR resource type',1;
 DECLARE @max_updated DATETIME2;
 SELECT @max_updated=MAX(last_updated) FROM (
  SELECT last_updated FROM silver.Patient WHERE @resource_type='Patient'
  UNION ALL SELECT last_updated FROM silver.Encounter WHERE @resource_type='Encounter'
  UNION ALL SELECT last_updated FROM silver.Observation WHERE @resource_type='Observation'
  UNION ALL SELECT last_updated FROM silver.Condition WHERE @resource_type='Condition'
 ) AS x;
 UPDATE control.fhir_watermark
 SET last_updated=CASE WHEN @max_updated IS NULL THEN last_updated
                       WHEN last_updated IS NULL OR @max_updated>last_updated THEN @max_updated
                       ELSE last_updated END,
     last_run_time=SYSUTCDATETIME()
 WHERE resource_type=@resource_type;
END;
GO
CREATE OR ALTER PROCEDURE silver.usp_Process_FHIR_Resource @resource_type VARCHAR(50)
AS
BEGIN
 SET NOCOUNT ON;
 IF @resource_type NOT IN ('Patient','Encounter','Observation','Condition')
  THROW 50003,'Unsupported FHIR resource type',1;
 IF @resource_type='Patient'
 BEGIN
  EXEC silver.usp_Upsert_Patient;
  EXEC silver.usp_Patient_SCD2;
 END;
 IF @resource_type='Encounter' EXEC silver.usp_Upsert_Encounter;
 IF @resource_type='Observation' EXEC silver.usp_Upsert_Observation;
 IF @resource_type='Condition' EXEC silver.usp_Upsert_Condition;
 EXEC control.usp_Update_FHIR_Watermark @resource_type=@resource_type;
END;
GO


====================================================================
-- 06_Reporting_Views.sql
====================================================================

-- Reporting views, reconstructed from the fields described during assessment.
CREATE OR ALTER VIEW dbo.vw_Patient_Summary AS
SELECT p.patient_id,p.family_name,p.given_name,p.gender,p.birth_date,p.last_updated,
 (SELECT COUNT(*) FROM silver.Encounter e WHERE e.patient_id=p.patient_id) AS encounter_count,
 (SELECT COUNT(*) FROM silver.Observation o WHERE o.patient_id=p.patient_id) AS observation_count,
 (SELECT COUNT(*) FROM silver.Condition c WHERE c.patient_id=p.patient_id) AS condition_count
FROM silver.Patient p;
GO
CREATE OR ALTER VIEW dbo.vw_Encounter_Summary AS
SELECT e.encounter_id,e.patient_id,p.family_name,p.given_name,e.status,e.encounter_class,
 e.start_date,e.end_date,e.last_updated
FROM silver.Encounter e LEFT JOIN silver.Patient p ON p.patient_id=e.patient_id;
GO
CREATE OR ALTER VIEW dbo.vw_Observation_Summary AS
SELECT o.observation_id,o.patient_id,o.encounter_id,o.status,o.observation_code,
 o.observation_name,o.observation_value,o.observation_unit,o.effective_date,o.last_updated
FROM silver.Observation o;
GO
CREATE OR ALTER VIEW dbo.vw_Condition_Summary AS
SELECT c.condition_id,c.patient_id,c.encounter_id,c.clinical_status,c.condition_code,
 c.condition_name,c.onset_date,c.recorded_date,c.last_updated
FROM silver.Condition c;
GO


====================================================================
-- 07_Final_Validation.sql
====================================================================

SELECT 'Patient' AS Resource,COUNT(*) AS Total FROM silver.Patient
UNION ALL SELECT 'Encounter',COUNT(*) FROM silver.Encounter
UNION ALL SELECT 'Observation',COUNT(*) FROM silver.Observation
UNION ALL SELECT 'Condition',COUNT(*) FROM silver.Condition;
SELECT resource_type,COUNT(*) AS staged_bundles FROM staging.fhir_raw GROUP BY resource_type;
SELECT resource_type,last_updated,last_run_time FROM control.fhir_watermark ORDER BY resource_type;
SELECT COUNT(*) AS history_rows,SUM(CASE WHEN is_current=1 THEN 1 ELSE 0 END) AS current_rows
FROM silver.Patient_History;
SELECT patient_id,COUNT(*) AS duplicate_count FROM silver.Patient GROUP BY patient_id HAVING COUNT(*)>1;
SELECT COUNT(*) AS patient_view_rows FROM dbo.vw_Patient_Summary;
SELECT COUNT(*) AS encounter_view_rows FROM dbo.vw_Encounter_Summary;
SELECT COUNT(*) AS observation_view_rows FROM dbo.vw_Observation_Summary;
SELECT COUNT(*) AS condition_view_rows FROM dbo.vw_Condition_Summary;


====================================================================
-- 08_Execution_Queries.sql
====================================================================

-- Commands used to execute the Silver upsert procedures.
-- Do not run these again merely to prepare the submission.
EXEC silver.usp_Upsert_Encounter;
EXEC silver.usp_Upsert_Observation;
EXEC silver.usp_Upsert_Condition;
GO
-- Common resource processor used by ADF (sample manual invocation)
-- EXEC silver.usp_Process_FHIR_Resource @resource_type = 'Patient';
-- EXEC silver.usp_Process_FHIR_Resource @resource_type = 'Encounter';
-- EXEC silver.usp_Process_FHIR_Resource @resource_type = 'Observation';
-- EXEC silver.usp_Process_FHIR_Resource @resource_type = 'Condition';
-- SCD2 procedure used by ADF for Patient
-- EXEC silver.usp_Patient_SCD2;


====================================================================
-- 09_Additional_Validation_Queries.sql
====================================================================

-- Queries used to inspect the resource counts and ensure Patient ID uniqueness.
SELECT 'Patient' AS Resource, COUNT(*) AS Total FROM silver.Patient
UNION ALL SELECT 'Encounter', COUNT(*) FROM silver.Encounter
UNION ALL SELECT 'Observation', COUNT(*) FROM silver.Observation
UNION ALL SELECT 'Condition', COUNT(*) FROM silver.Condition;
GO
SELECT patient_id, COUNT(*) AS duplicate_count
FROM silver.Patient GROUP BY patient_id HAVING COUNT(*) > 1;
GO
-- Inspect raw FHIR Bundle staging by resource.
SELECT resource_type, COUNT(*) AS total_bundles
FROM staging.fhir_raw GROUP BY resource_type;
GO
-- Inspect current and historical Patient versions.
SELECT patient_id, family_name, effective_from, effective_to, is_current
FROM silver.Patient_History ORDER BY patient_id, effective_from;
GO
-- Watermark values and last successful update times.
SELECT * FROM control.fhir_watermark ORDER BY resource_type;
GO
-- Reporting view sample queries.
SELECT TOP (20) * FROM dbo.vw_Patient_Summary;
SELECT TOP (20) * FROM dbo.vw_Encounter_Summary;
SELECT TOP (20) * FROM dbo.vw_Observation_Summary;
SELECT TOP (20) * FROM dbo.vw_Condition_Summary;

