################################################################################
# mobile-store — publisher stack
#
# Publishes the scope as the package np-mobile-store, visible to every organization,
# from each release: the specs of the released tag and the worker image the
# same release pushed, pinned by digest. Only the release workflow runs it,
# through actions-nullplatform's publish-package, which passes the three
# variables below as TF_VAR_*. The release contract (version from the tag,
# prerelease handling, guards) lives in tofu-modules' scope_package_publish.
################################################################################

variable "publisher_nrn" {
  description = "Owner NRN of the package: the publisher organization."
  type        = string
}

variable "release_tag" {
  description = "Release tag being published (vX.Y.Z): the package revision's version."
  type        = string
}

variable "image_digest" {
  description = "Digest of the worker image this release pushed (sha256:<64 hex>)."
  type        = string
}

module "publish" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_package_publish?ref=v9.16.0"

  nrn          = var.publisher_nrn
  release_tag  = var.release_tag
  image_digest = var.image_digest

  # The np- prefix keeps the global package and its specification apart from
  # the copies organizations registered from this repository: agent channels
  # route by specification slug, so the two must differ to live in one
  # organization. The specification keeps the plain name people read.
  package_slug             = "np-mobile-store"
  service_spec_name        = "Mobile store"
  service_path             = "mobile-store"
  image_repository         = "nullplatform/agent-plugins/scopes/mobile-store"
  local_specs_path         = abspath("${path.module}/..")
  service_spec_description = "Publishes mobile app binaries (Android, iOS) to a distribution channel: tester groups, app stores or an enterprise store"

  action_spec_names = [
    "create-scope",
    "delete-deployment",
    "delete-scope",
    "finalize-blue-green",
    "rollback-deployment",
    "start-blue-green",
    "start-initial",
    "switch-traffic",
    "update-scope",
  ]
}
