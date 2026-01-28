# Secret Server Migration - Reference Documentation

## Official Delinea Documentation

### REST API
- REST API Overview: https://docs.delinea.com/online-help/secret-server/api-scripting/rest-api/index.htm
- REST API PowerShell Scripts: https://docs.delinea.com/online-help/secret-server/api-scripting/rest-api/rest-api-powershell-scripts/index.htm
- REST API Examples: https://docs.delinea.com/online-help/secret-server/api-scripting/rest-api/examples/index.htm

### Import/Export
- Secret Import and Export Overview: https://docs.delinea.com/online-help/secret-server/secret-operations/secret-import-and-export/index.htm
- Importing Secrets: https://docs.delinea.com/online-help/secret-server-11-6-x/secret-import-and-export/importing-secrets/index.htm
- Exporting Secrets: https://docs.delinea.com/online-help/secret-server-11-5-x/secret-import-and-export/exporting-secrets/index.htm

### Release Notes (July 2025 - Bulk Operations Improvements)
- SSC July 22, 2025 Release: https://docs.delinea.com/online-help/secret-server/release-notes/ssc-rn-2025-07-22.htm
  - Bulk operations now handle "tens of thousands of secrets"
  - 20% performance improvement via request chunking
  - Bulk field updates in folder view
  - 66% improvement in secret search speed

### Migration Tool (Third-Party Sources)
- Secret Server Migration Tool: https://docs.delinea.com/online-help/secret-server-11-6-x/secret-import-and-export/secret-server-migration-tool/index.htm

## Community Resources

### PowerShell Module
- GitHub: https://github.com/thycotic-ps/thycotic.secretserver
- PowerShell Gallery: https://www.powershellgallery.com/packages/Thycotic.SecretServer/0.60.7
- Note: Community-supported, not officially supported by Delinea

## Key Technical Notes

### CSV Import Limitation
Standard CSV import does NOT preserve secret expiration dates. REST API import DOES preserve all fields.

### Duplicate Names
Configure before import: Settings > Configuration > General > Permission Options > "Allow Duplicate Secret Names"
Set to "Allow Duplicates" if source has duplicate names.

### TLS Requirements
Secret Server Cloud requires TLS 1.2/1.3. Add to PowerShell scripts:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

### Version Matching (XML Migration)
For XML import/export between on-prem and cloud, major release versions must match.

## Support Notice

Per Delinea documentation: "Migration is not supported by Delinea Technical Support"

This toolkit uses the REST API approach which provides full field preservation and is suitable for large-scale migrations (40K+ secrets) leveraging the July 2025 bulk operation improvements.
