# Credentials: in Cloud Shell the provider uses the signed-in admin's Application
# Default Credentials. Nothing Symbol-owned is ever used to apply this template.
provider "google" {
  project = var.project_id

  # Requests that need a quota project (Cloud Asset, Recommender, Service Usage)
  # are billed to the customer project, never to a gcloud default.
  user_project_override = true
  billing_project       = var.project_id

  # Added to every resource that supports labels (topics, subscriptions, dataset,
  # view). Label values allow only [a-z0-9_-], at most 63 characters.
  default_labels = local.labels
}
