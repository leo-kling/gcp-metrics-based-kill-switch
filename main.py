"""Cloud Function to disable billing for a GCP project."""

import base64
import json
import logging
import os

import functions_framework
from flask import Request
from google.cloud import billing_v1
from google.api_core import exceptions

# Constants
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID")
if GCP_PROJECT_ID is None:
    raise ValueError("GCP_PROJECT_ID environment variable is not set.")

APP_LOGGER = logging.getLogger(__name__)


@functions_framework.http
def kill_switch(request: Request) -> tuple[str, int]:
    """A simple HTTP Cloud Function that processes incident data and triggers billing disable."""
    try:
        body_json = request.get_json(silent=True)
        if body_json and "message" in body_json:
            encoded_data = body_json["message"].get("data")
            if encoded_data:
                decoded_data = base64.b64decode(encoded_data).decode("utf-8")
                incident_json = json.loads(decoded_data)
                APP_LOGGER.debug(
                    "Decoded Incident: %s", json.dumps(incident_json, indent=2)
                )

                # Validate that it's a proper incident structure
                if "incident" in incident_json:
                    incident = incident_json["incident"]
                    APP_LOGGER.info(
                        "Valid incident received: %s", incident.get("incident_id")
                    )

                    # Trigger kill switch
                    billing_manager = BillingManager()
                    billing_manager.disable_billing_for_the_project()

                    return "Billing disabled", 200
                else:
                    APP_LOGGER.warning("Invalid incident structure received")
                    return "Invalid incident format", 400
    except Exception as e:
        APP_LOGGER.error("Error processing request: %s", str(e))
        return "Error", 500

    return "No incident data", 400


class BillingManager:
    """Manages billing operations for GCP projects."""

    def __init__(self) -> None:
        """Initialize the BillingManager."""
        self.billing_client = billing_v1.CloudBillingClient()

    def disable_billing_for_the_project(self) -> None:
        """Disable billing for a project by removing its billing account.

        Based on: https://docs.cloud.google.com/billing/docs/how-to/disable-billing-with-notifications#create-cloud-run-function
        """
        resource_name = f"projects/{GCP_PROJECT_ID}"

        project_billing_info = billing_v1.ProjectBillingInfo(
            billing_account_name=""  # No Billing Account
        )

        APP_LOGGER.debug("Project Billing Info to update: %s", project_billing_info)

        request = billing_v1.UpdateProjectBillingInfoRequest(
            name=resource_name, project_billing_info=project_billing_info
        )

        try:
            response = self.billing_client.update_project_billing_info(request=request)
            APP_LOGGER.info("Disable billing response: %s", response)
            APP_LOGGER.critical("Billing disabled for project %s.", GCP_PROJECT_ID)
        except exceptions.PermissionDenied as e:
            APP_LOGGER.error(f"Failed to disable billing, check permissions. Error: {e}")
