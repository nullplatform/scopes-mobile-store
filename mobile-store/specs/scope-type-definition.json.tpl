{
  "name": "Mobile store",
  "description": "Publishes mobile app binaries (Android, iOS) to a distribution channel: tester groups, app stores or an enterprise store",
  "nrn": "{{ env.Getenv "NRN" }}",
  "provider_id": "{{ env.Getenv "SERVICE_SPECIFICATION_ID" }}",
  "provider_type": "service",
  "status": "active",
  "type": "custom"
}
