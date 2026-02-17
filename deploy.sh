#!/bin/bash

# Edit info below to match your environment
read -p "Enter GCP Project ID: " GCP_PROJECT_ID


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# FROM HERE, YOU DON'T NEED TO CHANGE A THING
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

# Login / Base config
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
gcloud auth login --project "$GCP_PROJECT_ID"
gcloud config set project "$GCP_PROJECT_ID"

gcloud services enable cloudresourcemanager.googleapis.com \
    cloudbilling.googleapis.com --project "$GCP_PROJECT_ID"

gcloud config set billing/quota_project "$GCP_PROJECT_ID"


# Computed Values / Constants
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
PROJECT_NUMBER=$(gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectNumber)')
if [ -z "$PROJECT_NUMBER" ]; then
  echo "Error: Could not retrieve Project Number. Check your authentication/project ID."
  exit 1
fi

TOPIC_NAME="metrics-based-kill-switch-topic"
EVENT_TRIGGER_NAME="metrics-based-kill-switch-trigger"
CLOUD_FUNCTION_NAME="metrics-based-kill-switch-function"
NOTIFICATION_CHAN_NAME="metrics-based-kill-switch-notification-channel"

BILLING_ACCOUNT=$(gcloud billing projects describe "${GCP_PROJECT_ID}" --format='value(billingAccountName)')
CLOUD_FUNCTION_SA_ID="function-invoker"
CLOUD_FUNCTION_SA="${CLOUD_FUNCTION_SA_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
NOTIFICATION_CHAN_SA="service-${PROJECT_NUMBER}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
PUB_SUB_SA="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
REGION="us-central1"

# Script Logic
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Enable required APIs
echo "Enabling required APIs..."
gcloud services enable monitoring.googleapis.com \
    pubsub.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    cloudfunctions.googleapis.com \
    eventarc.googleapis.com


echo "Giving grace period for APIs to be fully enabled..."
sleep 60


echo "Creating service account: ${CLOUD_FUNCTION_SA}..."
if ! gcloud iam service-accounts describe "${CLOUD_FUNCTION_SA}" > /dev/null 2>&1; then
    gcloud iam service-accounts create "${CLOUD_FUNCTION_SA_ID}" \
        --display-name="Eventarc to Cloud Run Invoker"
    
    echo "Waiting for service account to be fully created..."
    
    # Verify service account exists with retry logic
    attempt=0
    while [ $attempt -lt 10 ]; do
        if gcloud iam service-accounts describe "${CLOUD_FUNCTION_SA}" > /dev/null 2>&1; then
            echo "Service account created and verified."
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt 10 ]; then
            echo "Attempt $attempt/10 - Waiting 5 seconds..."
            sleep 5
        fi
    done
    
    if [ $attempt -eq 10 ]; then
        echo "Error: Service account creation failed after 10 attempts."
        exit 1
    fi
else
    echo "Service account already exists."
fi


echo "Granting Billing Project Manager role to the Cloud Run invoker..."
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member "serviceAccount:${CLOUD_FUNCTION_SA}" \
    --role "roles/billing.projectManager"


echo "Creating Pub/Sub topic..."
if ! gcloud pubsub topics describe "${TOPIC_NAME}" > /dev/null 2>&1; then
    gcloud pubsub topics create "${TOPIC_NAME}"
fi


echo "Creating Monitoring Notification Channel..."
# Note: This creates a new channel every time. You might want to check existence via list command in production.
gcloud alpha monitoring channels create \
    --display-name="${NOTIFICATION_CHAN_NAME}" \
    --type=pubsub \
    --channel-labels=topic=projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}


echo "Granting Pub/Sub Publisher role to the Monitoring SA..."
gcloud pubsub topics add-iam-policy-binding "${TOPIC_NAME}" \
    --member="serviceAccount:${NOTIFICATION_CHAN_SA}" \
    --role="roles/pubsub.publisher"


echo "Granting Token Creator role to the Pub/Sub SA..."
gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${PUB_SUB_SA}" \
    --role="roles/iam.serviceAccountTokenCreator"


echo "Waiting 60 seconds for IAM policies to propagate..."
sleep 60


gcloud functions deploy "${CLOUD_FUNCTION_NAME}" \
    --gen2 \
    --runtime python314 \
    --region "${REGION}" \
    --trigger-http \
    --no-allow-unauthenticated \
    --entry-point kill_switch \
    --source . \
    --set-env-vars "GCP_PROJECT_ID=${GCP_PROJECT_ID}" \
    --service-account "${CLOUD_FUNCTION_SA}"


echo "Granting Cloud Run Invoker role to the Cloud Function service account..."
gcloud functions add-invoker-policy-binding "${CLOUD_FUNCTION_NAME}" \
    --member="serviceAccount:${CLOUD_FUNCTION_SA}" \
    --project="${GCP_PROJECT_ID}" \
    --region="${REGION}"


echo "Creating Eventarc trigger..."
gcloud eventarc triggers create "${EVENT_TRIGGER_NAME}" \
    --service-account="${CLOUD_FUNCTION_SA}" \
    --location="${REGION}" \
    --transport-topic="projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}" \
    --destination-run-service="${CLOUD_FUNCTION_NAME}" \
    --destination-run-region="${REGION}" \
    --event-filters="type=google.cloud.pubsub.topic.v1.messagePublished"


echo "\n- - - - - - - - - - - - - - - - - -"
echo "Deployment Complete."
echo "IMPORTANT: Any Alert Policy reached will now trigger the kill switch function via:"
echo "notifications to the Pub/Sub topic: projects/${GCP_PROJECT_ID}/topics/${TOPIC_NAME}"
echo "- - - - - - - - - - - - - - - - - -"