# wxA to wxO Migration Automation Scripts

This directory contains scripts to automate the wxA (Watson Assistant) to wxO (Watson Orchestrate) migration process.

## Overview

The migration process involves:
1. **Extracting** instance metadata from wxA cluster
2. **Creating** matching instances in wxO cluster  
3. **Extracting** instance IDs from wxO cluster
4. **Generating** a mapping file for pgmig tool
5. **Using** the mapping file during PostgreSQL migration

## Scripts

### 1. `wxa_extract_instances.sh`
Extracts instance list from wxA PostgreSQL database.

**Usage:**
```bash
./wxa_extract_instances.sh <NAMESPACE> [OUTPUT_BASE]
```

**Example:**
```bash
# Extract from cpd namespace
./wxa_extract_instances.sh cpd

# Extract with custom output name
./wxa_extract_instances.sh cpd my_migration
```

**Output:**
- `wxa_instances.csv` - CSV format for instance creation (compatible with instancecreation_v2.sh)
- `wxa_instances.json` - JSON with full metadata including tenant_ids

---

### 2. `instancecreation_v2.sh`
Creates wxO instances from CSV file (existing script).

**Usage:**
```bash
./instancecreation_v2.sh <CSV_FILE> <NAMESPACE> <CPD_ROUTE> <AUTH> [USERNAME]
```

**Example:**
```bash
# Using API key
./instancecreation_v2.sh wxa_instances.csv cpd cpd.example.com <api_key> admin

# Using Bearer token
./instancecreation_v2.sh wxa_instances.csv cpd cpd.example.com eyJhbGci...
```

**Notes:**
- Instances are created sequentially with readiness checks
- Wait for each instance to be ready before proceeding to the next
- Maximum wait time: 30 minutes per instance

---

### 3. `wxo_extract_instances.sh`
Extracts instance IDs from wxO PostgreSQL after creation.

**Usage:**
```bash
./wxo_extract_instances.sh <NAMESPACE> [OUTPUT_FILE]
```

**Example:**
```bash
./wxo_extract_instances.sh cpd wxo_instances.json
```

**Output:**
- `wxo_instances.json` - JSON with instance names and tenant_ids

---

### 4. `wxa_generate_mapping.sh`
Generates pgmig-compatible mapping file by matching instance names.

**Usage:**
```bash
./wxa_generate_mapping.sh <WXA_JSON> <WXO_JSON> [OUTPUT_FILE]
```

**Example:**
```bash
./wxa_generate_mapping.sh wxa_instances.json wxo_instances.json instance_mapping.yaml
```

**Output:**
- `instance_mapping.yaml` - Mapping file for pgmig

**Format:**
```yaml
instance-mappings:
  e10001eb-6272-453a-bb43-3dcf0e765892: 00000000-0000-0000-1764-035503433645
  00000000-0000-0000-1764-032283900524: 00000000-0000-0000-1764-035353588112
```

---

## Complete Workflow

### Prerequisites
- `oc` CLI installed and logged in
- `jq` installed (for mapping generation)
- Access to both wxA and wxO clusters
- CPD API key or Bearer token for wxO cluster

### Step-by-Step Process

#### Step 1: Extract wxA Instances
```bash
# Login to wxA cluster
oc login <wxa-cluster-url>

# Extract instances
./wxa_extract_instances.sh cpd wxa_instances
```

**Output files:**
- `wxa_instances.csv` - For creating wxO instances
- `wxa_instances.json` - For mapping generation

---

#### Step 2: Create wxO Instances
```bash
# Login to wxO cluster
oc login <wxo-cluster-url>

# Create instances using the CSV
./instancecreation_v2.sh wxa_instances.csv cpd cpd.example.com <api_key> admin
```

**Notes:**
- This will create all instances listed in the CSV
- Each instance creation includes a readiness check
- The script will wait for each instance to be ready before proceeding

---

#### Step 3: Extract wxO Instances
```bash
# Still logged into wxO cluster
./wxo_extract_instances.sh cpd wxo_instances.json
```

**Output file:**
- `wxo_instances.json` - Contains wxO instance IDs for mapping

---

#### Step 4: Generate Mapping File
```bash
./wxa_generate_mapping.sh wxa_instances.json wxo_instances.json instance_mapping.yaml
```

**Output file:**
- `instance_mapping.yaml` - Ready to use with pgmig

The script will:
- Match instances by name
- Report any unmapped instances
- Generate YAML in pgmig format

---

#### Step 5: Use Mapping with pgmig
During PostgreSQL restore (Step 27 in migration guide):

```bash
# Inside the postgres pod
./pgmig --resourceController resourceController.yaml \
        --target postgres.yaml \
        --source store.dump_20251125-011455 \
        --wxo --force -m instance_mapping.yaml
```

---

## File Formats

### CSV Format (for instance creation)
```csv
id,service,version
instance-1,orchestrate,5.2.2
instance-2,orchestrate,5.2.2
monitoring,orchestrate,5.2.2
bdd-test,orchestrate,5.2.2
```

### JSON Format (wxA metadata)
```json
[
  {
    "wxa_tenant_id": "e10001eb-6272-453a-bb43-3dcf0e765892",
    "wxa_instance_id": "00000000-0000-0000-1764-032283900524",
    "wxa_name": "instance-1",
    "wxa_region": "us-south",
    "wxo_name": "instance-1"
  }
]
```

### JSON Format (wxO metadata)
```json
[
  {
    "name": "instance-1",
    "tenant_id": "00000000-0000-0000-1764-035503433645",
    "instance_id": "00000000-0000-0000-1764-035353588112",
    "region": "us-south"
  }
]
```

### YAML Format (pgmig mapping)
```yaml
instance-mappings:
  <wxa_tenant_id>: <wxo_tenant_id>
  <wxa_tenant_id>: <wxo_tenant_id>
```

---

## Special Instance Handling

### Monitoring Instance
- wxA region: `monitoring`
- wxO name: `monitoring`
- Automatically handled by scripts

### BDD Test Instance
- wxA: Unnamed or null name
- wxO name: `bdd-test`
- Automatically handled by scripts

### wxo-assistant-de Instance
- Created automatically by wxO
- Should already exist before running scripts
- Not included in CSV (skip in creation)

---

## Troubleshooting

### "Could not find postgres pod"
- Verify you're logged into the correct cluster
- Check the namespace is correct
- Verify Watson Assistant/Orchestrate is installed

### "No instances found"
- Check PostgreSQL database connectivity
- Verify instances exist and are not deleted
- Check database name (conversation_pprd_wa)

### "Unmapped instances"
- Review the unmapped instances list
- Verify all wxO instances were created successfully
- Check for name mismatches
- Manually map during pgmig execution if needed

### Instance Creation Timeout
- Increase timeout in instancecreation_v2.sh (max_wait variable)
- Check cluster resources
- Review instance provisioning logs

### jq not found
```bash
# macOS
brew install jq

# RHEL/CentOS
dnf install jq -y
```

---

## Integration with Migration Guide

These scripts automate portions of the migration guide (`5.X.X/5.X.X_Migrate_wxA_to_wxO_final_rev1.md`):

- **Step 5**: Use `wxa_extract_instances.sh`
- **Step 13**: Use `instancecreation_v2.sh` with generated CSV
- **Step 27**: Use generated mapping file with pgmig

---

## Quick Reference

```bash
# 1. Extract from wxA (logged into wxA cluster)
./wxa_extract_instances.sh cpd wxa_instances

# 2. Create in wxO (logged into wxO cluster)
./instancecreation_v2.sh wxa_instances.csv cpd cpd.example.com <api_key> admin

# 3. Extract from wxO (still in wxO cluster)
./wxo_extract_instances.sh cpd wxo_instances.json

# 4. Generate mapping (can run anywhere)
./wxa_generate_mapping.sh wxa_instances.json wxo_instances.json instance_mapping.yaml

# 5. Use with pgmig (inside postgres pod during migration)
./pgmig --resourceController resourceController.yaml \
        --target postgres.yaml \
        --source store.dump_YYYYMMDD-HHMMSS \
        --wxo --force -m instance_mapping.yaml
```

---

## Notes

- Scripts use `-k` flag for curl (insecure SSL). Remove for production with valid certificates.
- Instance creation is sequential with readiness checks between each.
- Mapping generation requires exact name matches (case-sensitive).
- Always review generated files before using them.
- Keep backup copies of all generated files.
- The CSV format is compatible with the existing `instancecreation_v2.sh` script.

---

## Support

For issues or questions:
1. Check script help: `<script_name> --help`
2. Review the main migration guide: `5.X.X/5.X.X_Migrate_wxA_to_wxO_final_rev1.md`
3. Verify prerequisites are met
4. Check cluster connectivity and permissions