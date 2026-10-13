{
  "name": "Mobile store",
  "type": "scope",
  "assignable_to": "any",
  "use_default_actions": false,
  "available_actions": [
    "create-scope",
    "update-scope",
    "delete-scope",
    "start-initial",
    "start-blue-green",
    "switch-traffic",
    "finalize-blue-green",
    "rollback-deployment",
    "delete-deployment"
  ],
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "selectors": {
    "category": "Scope",
    "imported": false,
    "provider": "Agent",
    "sub_category": "Mobile store"
  },
  "dimensions": {},
  "scopes": {},
  "attributes": {
    "schema": {
      "type": "object",
      "required": ["platform", "channel"],
      "properties": {
        "asset_type": {
          "type": "string",
          "default": "bundle",
          "export": false,
          "description": "Asset type this scope deploys. Mobile binaries are registered as bundle assets because the asset API only accepts the platform's built-in types; switch to a mobile-specific type once nullplatform adds one"
        },
        "platform": {
          "type": "string",
          "title": "Platform",
          "description": "Which mobile binaries this scope publishes. The build must produce the matching artifacts (APK/AAB for Android, IPA for iOS).",
          "default": "android",
          "oneOf": [
            { "const": "android", "title": "Android" },
            { "const": "ios", "title": "iOS" },
            { "const": "both", "title": "Android and iOS" }
          ],
          "editableOn": ["create"]
        },
        "channel": {
          "type": "string",
          "title": "Distribution channel",
          "description": "Who receives each deployment: your own team, a wider group of beta testers, or every end user.",
          "default": "internal",
          "oneOf": [
            { "const": "internal", "title": "Internal testers" },
            { "const": "testers", "title": "External testers / beta" },
            { "const": "production", "title": "Production" }
          ],
          "editableOn": ["create", "update"]
        },
        "rollout_percentage": {
          "type": "integer",
          "title": "Initial rollout percentage",
          "description": "Share of users that gets a new version first, on channels that support gradual rollout. Channels without gradual rollout ignore this value and deliver to everyone at once.",
          "default": 5,
          "minimum": 1,
          "maximum": 100,
          "editableOn": ["create", "update"]
        }
      },
      "uiSchema": {
        "type": "VerticalLayout",
        "elements": [
          { "type": "Control", "scope": "#/properties/platform" },
          { "type": "Control", "scope": "#/properties/channel" },
          { "type": "Control", "scope": "#/properties/rollout_percentage" }
        ]
      }
    },
    "values": {}
  }
}
