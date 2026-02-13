#!/bin/bash


# Edit info below to match your environment
GCP_PROJECT_ID="YOUR_PROJECT_ID_HERE"


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# FROM HERE, YOU DON'T NEED TO CHANGE A THING
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -


# Login / Base config
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
gcloud auth login --project "$GCP_PROJECT_ID" --billing-project "$GCP_PROJECT_ID"
gcloud config set project "$GCP_PROJECT_ID"
gcloud services enable cloudresourcemanager.googleapis.com
gcloud services enable cloudbilling.googleapis.com
gcloud config set billing/quota_project "$GCP_PROJECT_ID"


# Computed Values / Constants
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectNumber)')

TOPIC_NAME="metrics-based-kill-switch-topic"
EVENT_TRIGGER_NAME="metrics-based-kill-switch-trigger"
CLOUD_FUNCTION_NAME="metrics-based-kill-switch-function"
NOTIFICATION_CHAN_NAME="metrics-based-kill-switch-notification-channel"

BILLING_ACCOUNT=$(gcloud billing projects describe "${GCP_PROJECT_ID}" --format='value(billingAccountName)')
CLOUD_FUNCTION_SA="function-invoker@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
NOTIFICATION_CHAN_SA="service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
PUB_SUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"


# Script Logic
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Enable required APIs
echo "Enabling required APIs..."
gcloud services enable monitoring.googleapis.com 
gcloud services enable pubsub.googleapis.com
gcloud services enable artifactregistry.googleapis.com
gcloud services enable cloudbuild.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable cloudfunctions.googleapis.com
gcloud services enable eventarc.googleapis.com


echo "Giving grace period for APIs to be fully enabled..."
sleep 60


echo "Creating service account for Cloud Run invoker..."
gcloud iam service-accounts create function-invoker \
    --display-name="Eventarc to Cloud Run Invoker"


echo "Granting Billing Project Manager role to the Cloud Run invoker service account..."
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member "serviceAccount:${CLOUD_FUNCTION_SA}" \
    --role "roles/billing.projectManager"


echo "Creating Pub/Sub topic..."
gcloud pubsub topics create "${TOPIC_NAME}"


echo "Creating Monitoring Notification Channel..."
gcloud alpha monitoring channels create \
    --display-name="${NOTIFICATION_CHAN_NAME}" \
    --type=pubsub \
    --channel-labels=topic=projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}


echo "Granting Pub/Sub Publisher role to the monitoring notification service account..."
gcloud pubsub topics add-iam-policy-binding "${TOPIC_NAME}" \
    --member="serviceAccount:${NOTIFICATION_CHAN_SA}" \
    --role="roles/pubsub.publisher"


echo "Granting Service Account Token Creator role to the Pub/Sub service account..."
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${PUB_SUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator"


echo "Deploying Cloud Function..."
gcloud functions deploy "${CLOUD_FUNCTION_NAME}" \
    --gen2 \
    --runtime python314 \
    --region us-central1 \
    --trigger-http \
    --no-allow-unauthenticated \
    --entry-point kill_switch \
    --source . \
    --set-env-vars "GCP_PROJECT_ID=${GCP_PROJECT_ID}" \
    --service-account "${CLOUD_FUNCTION_SA}"


echo "Granting Cloud Run Invoker role to the Cloud Function service account..."
gcloud functions add-invoker-policy-binding "${CLOUD_FUNCTION_NAME}" \
    --member="serviceAccount:${CLOUD_FUNCTION_SA}" \
    --project="${GCP_PROJECT_ID}"


echo "Creating Eventarc trigger to connect Pub/Sub topic to Cloud Run service..."
gcloud eventarc triggers create "${EVENT_TRIGGER_NAME}" \
    --service-account="${CLOUD_FUNCTION_SA}" \
    --location=us-central1 \
    --transport-topic="projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}" \
    --destination-run-service="${CLOUD_FUNCTION_NAME}" \
    --destination-run-region=us-central1 \
    --event-filters="type=google.cloud.pubsub.topic.v1.messagePublished"
