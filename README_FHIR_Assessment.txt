FHIR DATA ENGINEERING ASSESSMENT
================================

Source: Public HAPI FHIR R4 test API
Flow: FHIR REST API -> Azure Data Factory -> ADLS Gen2 Bronze JSON -> Azure SQL raw staging -> Silver relational tables -> SQL reporting views.

Four resource types are processed: Patient, Encounter, Observation, and Condition.

ADF pipelines included in the exported ARM template:

- PL_FHIR_Ingest_Resource: Fetches FHIR Bundle pages and saves JSON to Bronze storage.
- PL_FHIR_Bronze_To_SQL: Reads Bronze files, inserts raw JSON into SQL staging, and runs resource-specific SQL processing.
- PL_FHIR_Master_Orchestration: Runs ingestion followed by Bronze-to-SQL processing.

I implemented a FHIR data engineering pipeline using Azure Data Factory, Azure Data Lake Storage Gen2, and Azure SQL Database. The main objective was to extract healthcare data from the public HAPI FHIR R4 API, store the raw data, transform it into relational tables, and make it available for reporting.

I worked with four FHIR resources: Patient, Encounter, Observation, and Condition. I created the `PL_FHIR_Ingest_Resource` pipeline in Azure Data Factory to retrieve data from the REST API. I implemented pagination to fetch multiple pages and stored the JSON responses in the Bronze container of ADLS Gen2. The files are organized by resource type, year, month, day, and pipeline run ID.

After ingestion, I created the `PL_FHIR_Bronze_To_SQL` pipeline to read the JSON files from Bronze and load them into the `staging.fhir_raw` table in Azure SQL Database. I used Get Metadata, ForEach, Lookup, and Stored Procedure activities to process the files.

For the Silver layer, I created separate tables for Patient, Encounter, Observation, and Condition. I implemented SQL stored procedures to extract the required fields from the FHIR JSON, remove duplicate resource IDs, and perform upsert operations. I also created a common stored procedure, `silver.usp_Process_FHIR_Resource`, to process the resource type passed from ADF.

For Patient data, I implemented SCD Type 2 using the `silver.Patient_History` table to maintain historical records whenever patient information changes. I also implemented incremental loading using the `control.fhir_watermark` table and the FHIR `_lastUpdated` parameter.

To automate the process, I created `PL_FHIR_Master_Orchestration`, which executes the ingestion pipeline followed by the Bronze-to-SQL pipeline. I tested the master pipeline successfully with the Patient resource.

The pipeline uses parameters such as `pResource`, `pCount`, `pLastUpdated`, `pFolderPath`, and `pRunId`. During testing, I used a page size of five records and limited pagination to approximately three pages to avoid long-running executions.

After execution, I validated the Silver tables using SQL queries. The final results contained 30 Patient records, 15 Encounter records, 15 Observation records, and 15 Condition records, giving a total of 75 records. I also checked for duplicate Patient IDs and confirmed that no duplicates were returned. I created reporting views for all four resource types.

To deploy the solution in another environment, the required Azure Data Factory, ADLS Gen2, and Azure SQL Database resources must be available. The exported ADF ARM template can be deployed, the SQL scripts can be executed to create the database objects, and the linked services must be configured securely. The master pipeline can then be executed by passing the required FHIR resource type.

For this assessment, I used a public FHIR test API rather than a production healthcare system. I tested the solution with a limited number of pages, so it does not represent a complete extraction of all available records. The watermark implementation would require additional handling for incomplete batches in a production environment. Patient history tracking is implemented using SCD Type 2, while the remaining resources use standard upsert logic. Since the resources were retrieved independently, some references between resource types may not match.

The submission includes the exported ADF template, SQL scripts, and project documentation. Credentials, passwords, access tokens, storage keys, connection strings, and sensitive patient data are not intentionally included. Environment-specific connections must be configured securely during deployment.

