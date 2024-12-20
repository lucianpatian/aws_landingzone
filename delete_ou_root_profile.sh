#!/bin/bash

# Local variables
PARENT_ID="ou-"
TASK_POLICY_ARN="arn=arn:aws:iam::aws:policy/root-task/IAMDeleteRootUserCredentials"

# Save the initial AWS CLI credentials from the Orga account
INITIAL_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
INITIAL_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
INITIAL_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

# Verify initial AWS CLI credentials
aws sts get-caller-identity > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Unable to locate initial AWS credentials. Please configure credentials by running 'aws configure'."
  exit 1
fi

# List all OU accounts
account_ids=$(aws organizations list-accounts-for-parent --parent-id $PARENT_ID --query 'Accounts[?Status==`ACTIVE`].Id' --output text | tr '\t' '\n')

# Function to assume root role and delete login profile and deactivate MFA devices
assume_root_and_delete_resources() {
  local account_id=$1
  
  # Assume the root role
  creds=$(aws sts assume-root --region us-east-1 --target-principal ${account_id} --task-policy-arn ${TASK_POLICY_ARN} --duration-seconds 900 2>&1)
  
  if [ $? -ne 0 ]; then
    echo "Failed to assume root role for account ${account_id}: $creds"
    return
  fi

  export AWS_ACCESS_KEY_ID=$(echo $creds | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo $creds | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo $creds | jq -r '.Credentials.SessionToken')

  # Delete login profile for the root user
  delete_profile=$(aws iam delete-login-profile 2>&1)
  
  if [ $? -ne 0 ]; then
    if echo "$delete_profile" | grep -q "NoSuchEntity"; then
      echo "There is no login profile for the root user in account ${account_id}."
    else
      echo "Failed to delete login profile for root user in account ${account_id}: $delete_profile"
    fi
  else
    echo "Deleted login profile for root user in account ${account_id}."
  fi

  # List MFA devices for the root user
  mfa_devices=$(aws iam list-mfa-devices --query 'MFADevices[*].SerialNumber' --output text 2>&1)

  if [ $? -ne 0 ]; then
    echo "Failed to list MFA devices for root user in account ${account_id}: $mfa_devices"
  else
    # Iterate through each MFA device and deactivate it
    for mfa_device in $mfa_devices; do
      deactivate_mfa_device=$(aws iam deactivate-mfa-device --serial-number ${mfa_device} 2>&1)
      if [ $? -ne 0 ]; then
        echo "Failed to deactivate MFA device ${mfa_device} for root user in account ${account_id}: $deactivate_mfa_device"
      else
        echo "Deactivated MFA device ${mfa_device} for root user in account ${account_id}."
      fi
    done
  fi

  # Unset AWS credentials
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  # Restore initial AWS credentials
  export AWS_ACCESS_KEY_ID=$INITIAL_AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$INITIAL_AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN=$INITIAL_AWS_SESSION_TOKEN
}

# Iterate through each account and perform the actions
for account_id in $account_ids; do
  if [ -n "$account_id" ]; then
    echo "Processing account ID: $account_id"
    assume_root_and_delete_resources $account_id
  fi
done
