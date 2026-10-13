{
  "name": "Mobile store",
  "description": "Configuration for mobile store scopes: which signing, distribution and gate implementations run for a namespace or dimension. The android and ios objects configure each platform that the scopes of that namespace or dimension will publish; the developer picks the platform on the scope.",
  "category": "scope-configurations",
  "icon": "mdi:cellphone-arrow-down",
  "visible_to": [
    "{{ env.Getenv "NRN" }}"
  ],
  "allow_dimensions": true,
  "schema": {
    "type": "object",
    "required": [
      "signing_layer",
      "distribution_layer",
      "gate_layer",
      "assets"
    ],
    "allOf": [
      {
        "if": {
          "properties": {
            "distribution_layer": {
              "const": "firebase"
            }
          },
          "required": [
            "distribution_layer"
          ]
        },
        "then": {
          "required": [
            "firebase"
          ],
          "properties": {
            "firebase": {
              "required": [
                "project",
                "credentials_secret"
              ]
            }
          }
        }
      },
      {
        "if": {
          "properties": {
            "signing_layer": {
              "const": "keyvault"
            }
          },
          "required": [
            "signing_layer"
          ]
        },
        "then": {
          "required": [
            "android"
          ],
          "properties": {
            "android": {
              "required": [
                "keystore_secret"
              ]
            }
          }
        }
      }
    ],
    "properties": {
      "signing_layer": {
        "type": "string",
        "title": "Signing layer",
        "description": "How the binary gets its release signature before it is published.",
        "default": "prebuilt",
        "oneOf": [
          {
            "const": "prebuilt",
            "title": "Binary is already signed by CI"
          },
          {
            "const": "keyvault",
            "title": "Sign with a keystore stored in the secrets manager"
          },
          {
            "const": "match",
            "title": "fastlane match repository"
          }
        ]
      },
      "distribution_layer": {
        "type": "string",
        "title": "Distribution layer",
        "description": "Where the binary is published. The developer's channel (internal, testers, production) maps to the groups or tracks of this distribution.",
        "default": "firebase",
        "oneOf": [
          {
            "const": "firebase",
            "title": "Firebase App Distribution"
          },
          {
            "const": "app-store",
            "title": "TestFlight / App Store Connect"
          },
          {
            "const": "google-play",
            "title": "Google Play tracks"
          },
          {
            "const": "foundry-eas",
            "title": "Volt MX Foundry Enterprise App Store"
          },
          {
            "const": "intune",
            "title": "Microsoft Intune MDM"
          }
        ]
      },
      "gate_layer": {
        "type": "string",
        "title": "Gate layer",
        "description": "Whether a deployment waits for an external approval (such as a store review) before it is considered finished.",
        "default": "none",
        "oneOf": [
          {
            "const": "none",
            "title": "No external approval"
          },
          {
            "const": "store-review",
            "title": "Wait for the store review asynchronously"
          }
        ]
      },
      "firebase": {
        "type": "object",
        "title": "Firebase App Distribution",
        "description": "Project and credentials used when the distribution layer is Firebase App Distribution.",
        "properties": {
          "project": {
            "type": "string",
            "title": "Project",
            "description": "Firebase project ID that owns the registered apps (e.g. my-company-mobile)."
          },
          "app_id_android": {
            "type": "string",
            "title": "Android app ID",
            "description": "Firebase app ID of the Android app (e.g. 1:1234567890:android:abcdef). Validated at deploy time by the scope when the platform is used."
          },
          "app_id_ios": {
            "type": "string",
            "title": "iOS app ID",
            "description": "Firebase app ID of the iOS app (e.g. 1:1234567890:ios:abcdef). Validated at deploy time by the scope when the platform is used."
          },
          "credentials_secret": {
            "type": "string",
            "title": "Credentials secret",
            "description": "Name of the secret in the secrets manager that holds the service account JSON with the Firebase App Distribution Admin role."
          }
        }
      },
      "android": {
        "type": "object",
        "title": "Android",
        "description": "Identity and signing material of the Android app. Used by every scope of this namespace or dimension that publishes Android binaries.",
        "properties": {
          "package": {
            "type": "string",
            "title": "Package name",
            "description": "Application ID of the Android app (e.g. ar.io.nullplatform.sample). Validated at deploy time by the scope when the platform is used."
          },
          "keystore_secret": {
            "type": "string",
            "title": "Keystore secret",
            "description": "Name of the secret in the secrets manager that holds the release keystore and its passwords. Required when the signing layer signs with a stored keystore."
          }
        }
      },
      "ios": {
        "type": "object",
        "title": "iOS",
        "description": "Identity and store credentials of the iOS app. Used by every scope of this namespace or dimension that publishes iOS binaries.",
        "properties": {
          "bundle_id": {
            "type": "string",
            "title": "Bundle ID",
            "description": "Bundle identifier of the iOS app (e.g. io.nullplatform.sample). Validated at deploy time by the scope when the platform is used."
          },
          "app_store_connect_key_secret": {
            "type": "string",
            "title": "App Store Connect key secret",
            "description": "Name of the secret in the secrets manager that holds the App Store Connect API key (issuer ID, key ID and .p8 contents). Validated at deploy time by the scope when the platform is used."
          }
        }
      },
      "assets": {
        "type": "object",
        "title": "Assets",
        "description": "Bucket where the CI uploads the compiled binaries that the scope publishes.",
        "required": [
          "bucket"
        ],
        "properties": {
          "bucket": {
            "type": "string",
            "title": "Bucket",
            "description": "Name of the bucket that stores the build assets (e.g. assets-aws-mobile)."
          },
          "region": {
            "type": "string",
            "title": "Region",
            "description": "Region of the assets bucket.",
            "default": "us-east-1"
          }
        }
      }
    },
    "uiSchema": {
      "type": "VerticalLayout",
      "elements": [
        {
          "type": "Categorization",
          "elements": [
            {
              "type": "Category",
              "label": "Layers",
              "elements": [
                {
                  "type": "Control",
                  "scope": "#/properties/signing_layer",
                  "options": {
                    "format": "radio-cards"
                  }
                },
                {
                  "type": "Control",
                  "scope": "#/properties/distribution_layer",
                  "options": {
                    "format": "radio-cards"
                  }
                },
                {
                  "type": "Control",
                  "scope": "#/properties/gate_layer",
                  "options": {
                    "format": "radio-cards"
                  }
                }
              ]
            },
            {
              "type": "Category",
              "label": "Firebase",
              "rule": {
                "effect": "HIDE",
                "condition": {
                  "scope": "#/properties/distribution_layer",
                  "schema": {
                    "not": {
                      "const": "firebase"
                    }
                  }
                }
              },
              "elements": [
                {
                  "type": "Control",
                  "scope": "#/properties/firebase/properties/project"
                },
                {
                  "type": "Control",
                  "scope": "#/properties/firebase/properties/app_id_android"
                },
                {
                  "type": "Control",
                  "scope": "#/properties/firebase/properties/app_id_ios"
                },
                {
                  "type": "Control",
                  "scope": "#/properties/firebase/properties/credentials_secret"
                }
              ]
            },
            {
              "type": "Category",
              "label": "Android",
              "elements": [
                {
                  "type": "Control",
                  "scope": "#/properties/android/properties/package"
                },
                {
                  "rule": {
                    "effect": "HIDE",
                    "condition": {
                      "scope": "#/properties/signing_layer",
                      "schema": {
                        "not": {
                          "const": "keyvault"
                        }
                      }
                    }
                  },
                  "type": "Control",
                  "scope": "#/properties/android/properties/keystore_secret"
                }
              ]
            },
            {
              "type": "Category",
              "label": "iOS",
              "elements": [
                {
                  "type": "Control",
                  "scope": "#/properties/ios/properties/bundle_id"
                },
                {
                  "type": "Control",
                  "scope": "#/properties/ios/properties/app_store_connect_key_secret"
                }
              ]
            },
            {
              "type": "Category",
              "label": "Assets",
              "elements": [
                {
                  "type": "Control",
                  "scope": "#/properties/assets/properties/bucket"
                },
                {
                  "type": "Control",
                  "scope": "#/properties/assets/properties/region"
                }
              ]
            }
          ]
        }
      ]
    }
  }
}
