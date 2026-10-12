#!/usr/bin/env bash
# =============================================================================
#  CS 446 — OpenCSUSM
#  Run your own language model on one EC2 instance, inside a $100 budget.
#
#  This file is the DELIVERABLE. Submit it with your own choices filled in and
#  the output of STAGE 6 pasted at the bottom as a comment.
#
#      bash opencsusm.sh 1      # check quota and price BEFORE you plan anything
#      bash opencsusm.sh 2      # launch
#      bash opencsusm.sh 3      # install the engine      (runs ON the instance)
#      bash opencsusm.sh 4      # serve the model         (runs ON the instance)
#      bash opencsusm.sh 5      # open the tunnel         (runs on your laptop)
#      bash opencsusm.sh 6      # the test that must pass
#      bash opencsusm.sh 7      # STOP   — keeps the disk, stops the meter
#      bash opencsusm.sh 8      # DELETE — removes everything
#
#  TWO PATHS. Pick one with MODE below and say in your report why.
#    gpu  g4dn.xlarge + vLLM     fast, teaches GPU sizing, NEEDS A QUOTA INCREASE
#    cpu  c7i.2xlarge + Ollama   slower, cheaper, works on a brand-new account
#
#  Prices are us-east-1 on-demand, from the AWS Price List API, 2026-10-06.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------- YOUR CHOICES
MODE=cpu # <-- gpu | cpu
REGION=us-east-1
OWNER=shirley                     # <-- YOUR last name, lower case
KEYNAME=cs446-shirley-midterm-key # <-- an EC2 key pair you already own

# Network configuration
VPC_CIDR_BLOCK="10.20.0.0/16"
SUBNET_CIDR_BLOCK="10.20.1.0/24"

# CPU Path and instance configuration
INSTANCE_TYPE="m7i-flex.large"
MODEL="qwen2.5:0.5b"
APP_PORT="11434"
SSH_USER="ubuntu"

if [ "$MODE" = "gpu" ]; then
    # g4dn.xlarge  $0.5260/hr  T4 16 GB   190 hours on $100   <-- recommended
    # g6.xlarge    $0.8048/hr  L4 24 GB   124 hours on $100
    # g5.xlarge    $1.0060/hr  A10G 24 GB  99 hours on $100
    INSTANCE=g4dn.xlarge
    RATE=0.5260
    PORT=8000
    ENGINE=vLLM
    MODEL=Qwen/Qwen2.5-0.5B-Instruct
    AMI_PARAM=/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id
    DISK=100
else
    # c7i.2xlarge    $0.3570/hr  8 vCPU     280 hours on $100   <-- no quota needed
    # m7i.xlarge     $0.2016/hr  4 vCPU     496 hours on $100   slower still
    # m7i-flex.large $0.0957/hr  2 vCPU    1045 hours on $100   flexible option

    INSTANCE=m7i-flex.large
    RATE=0.0957
    PORT=11434
    ENGINE=Ollama
    MODEL=qwen2.5:0.5b
    AMI_PARAM=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
    DISK=40
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${SCRIPT_DIR}/.opencsusm-state"
KEY_FILE="${SCRIPT_DIR}/${KEYNAME}.pem"
AZ="${REGION}a"
COURSE_TAG="CS446"
OWNER_TAG="$OWNER"
LAB_TAG="midterm"
PROJECT_NAME_TAG="${COURSE_TAG}-${OWNER_TAG}-${LAB_TAG}"

# Persist IDs from newly created resources for later stages and safe teardown.
save_value() {
    printf "%s=%q\n" "$1" "$2" >>"$STATE"
    chmod 600 "$STATE"
}
stage="${1:-}"
[ -z "$stage" ] && {
    sed -n '2,22p' "$0"
    exit 0
}

# =============================================================================
case "$stage" in

# --- 1 ------------------------------------------------- can you even launch it
1)
    echo "== OpenCSUSM: $MODE path =========================================="
    echo "   $INSTANCE  +  $ENGINE  +  $MODEL"
    # Displays AWS account identity.
    aws sts get-caller-identity --query Arn --output text

    # Checks if the selected mode is GPU or CPU and provides relevant info.
    if [ "$MODE" = "gpu" ]; then
        echo
        echo "-- Running On-Demand G instances: your vCPU limit"
        # A brand-new AWS account very often has a limit of ZERO here. If it is 0
        # you cannot launch any G instance and retrying will not help. Request an
        # increase: Service Quotas -> EC2 -> quota code L-DB2E81BA -> ask for 8.
        # It can take hours. Do this on day one, not the night before.

        # Queries the current On-Demand G instance quota.
        aws service-quotas get-service-quota --region "$REGION" \
            --service-code ec2 --quota-code L-DB2E81BA \
            --query '{quota:Quota.QuotaName,value:Quota.Value}' --output table ||
            echo "   could not read the quota - open the Service Quotas console"
        echo "   A value of 0.0 means STOP and switch MODE=cpu, or request more."
    else
        echo
        echo "-- The CPU path uses an M-family instance, subject to standard On-Demand quota."
        echo "   This command checks my account's Running On-Demand G and VT instance quota"
        echo "   and is measured in vCPUs because GPU instances require different numbers of"
        echo "   vCPUs. The CPU lane is sufficient for the small 0.5B model."
    fi

    # Checks G/VT capacity in either lane; quota is denominated in vCPUs.
    aws service-quotas get-service-quota --region "$REGION" \
        --service-code ec2 --quota-code L-DB2E81BA \
        --query '{quota:Quota.QuotaName,value:Quota.Value}' --output table
    echo
    echo "-- $INSTANCE price, from the price list, not from memory"
    aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
        --filters "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE" \
        "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
        "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
        "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
        "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
        "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
        --max-results 1 --output json |
        python3 -c "import json,sys;d=json.load(sys.stdin);p=json.loads(d['PriceList'][0]);\
[print('   \$%s / hour' % v['pricePerUnit']['USD']) for t in p['terms']['OnDemand'].values() \
 for v in t['priceDimensions'].values()]"
    echo "   At \$$RATE/hour, \$100 buys $(python3 -c "print(round(100/$RATE))") hours."
    echo "   Budget 3-4 hours of real work. The rest is your safety margin."
    echo "   I chose to use the CPU lane because it is lower-cost and this model does not require a GPU."
    echo "   It also had more RAm than the other available options. while going up to 15 GB. I was able to"
    echo "   fully utilize the available memory for my workload well underbudget."
    ;;

# --- 2 ---------------------------------------------------------------- launch
2)
    echo "== Launching $INSTANCE ($MODE) ======================================"

    # This key pair already exists in AWS. Use the matching locally saved private key.
    [[ -f "$KEY_FILE" ]] || {
        echo "Private key not found: $KEY_FILE" >&2
        exit 1
    }
    chmod 400 "$KEY_FILE"
    aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEYNAME" >/dev/null
    MYIP=$(curl -fsS --max-time 15 https://checkip.amazonaws.com | tr -d '\r\n')
    [[ "$MYIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "Invalid public IPv4: $MYIP" >&2
        exit 1
    }
    AMI=$(aws ssm get-parameter --region "$REGION" --name "$AMI_PARAM" \
        --query 'Parameter.Value' --output text)
    echo "Using AMI $AMI and SSH source $MYIP/32"
    touch "$STATE"
    chmod 600 "$STATE"

    # Creates a VPC.
    VPC_ID=$(aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR_BLOCK" \
        --query 'Vpc.VpcId' --output text)
    # Saves the VPC ID to the state file for later stages.
    save_value VPC_ID "$VPC_ID"
    # Tags the VPC with relevant info for teardown..
    aws ec2 create-tags --region "$REGION" --resources "$VPC_ID" --tags \
        Key=Name,Value="$PROJECT_NAME_TAG-vpc" Key=Course,Value="$COURSE_TAG" \
        Key=Owner,Value="$OWNER_TAG" Key=Lab,Value="$LAB_TAG" Key=Project,Value=OpenCSUSM
    # Enables DNS support and hostnames for the VPC.
    aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
    aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    echo "VPC created: $VPC_ID"

    # Creates and configures a public subnet in this VPC.
    SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
        --cidr-block "$SUBNET_CIDR_BLOCK" --availability-zone "$AZ" \
        --query 'Subnet.SubnetId' --output text)
    # Saves the Subnet ID to the state file for later stages.
    save_value SUBNET_ID "$SUBNET_ID"
    # Tags the Subnet with relevant info for teardown.
    aws ec2 create-tags --region "$REGION" --resources "$SUBNET_ID" --tags \
        Key=Name,Value="$PROJECT_NAME_TAG-subnet" Key=Course,Value="$COURSE_TAG" \
        Key=Owner,Value="$OWNER_TAG" Key=Lab,Value="$LAB_TAG" Key=Project,Value=OpenCSUSM
    # Configures the subnet to automatically assign public IP addresses to instances launched within it.
    aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" \
        --map-public-ip-on-launch '{"Value":true}'
    echo "Subnet created: $SUBNET_ID"

    # Creates and attaches an internet gateway for outbound and SSH connectivity.
    IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
        --query 'InternetGateway.InternetGatewayId' --output text)
    # Saves the Internet Gateway ID to the state file for later stages.
    save_value IGW_ID "$IGW_ID"
    # Tags the Internet Gateway with relevant info for teardown.
    aws ec2 create-tags --region "$REGION" --resources "$IGW_ID" --tags \
        Key=Name,Value="$PROJECT_NAME_TAG-igw" Key=Course,Value="$COURSE_TAG" \
        Key=Owner,Value="$OWNER_TAG" Key=Lab,Value="$LAB_TAG" Key=Project,Value=OpenCSUSM
    # Attaches the internet gateway to the VPC.
    aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

    # Creates a route table and routes Internet traffic from the public subnet through the gateway.
    ROUTE_TABLE_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
        --query 'RouteTable.RouteTableId' --output text)
    # Saves the Route Table ID to the state file for later stages.
    save_value ROUTE_TABLE_ID "$ROUTE_TABLE_ID"
    # Tags the Route Table with relevant info for teardown.
    aws ec2 create-tags --region "$REGION" --resources "$ROUTE_TABLE_ID" --tags \
        Key=Name,Value="$PROJECT_NAME_TAG-rt" Key=Course,Value="$COURSE_TAG" \
        Key=Owner,Value="$OWNER_TAG" Key=Lab,Value="$LAB_TAG" Key=Project,Value=OpenCSUSM
    # Creates a default route to the Internet Gateway.
    aws ec2 create-route --region "$REGION" --route-table-id "$ROUTE_TABLE_ID" \
        --destination-cidr-block '0.0.0.0/0' --gateway-id "$IGW_ID"
    # Associates the route table with the public subnet.
    ROUTE_ASSOCIATION_ID=$(aws ec2 associate-route-table --region "$REGION" \
        --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_ID" \
        --query 'AssociationId' --output text)
    # Saves the Route Association ID to the state file for later stages.
    save_value ROUTE_ASSOCIATION_ID "$ROUTE_ASSOCIATION_ID"

    # Creates a security group inside the new VPC. Open SSH only to this laptop.
    SECURITY_GROUP_ID=$(aws ec2 create-security-group --region "$REGION" \
        --vpc-id "$VPC_ID" --group-name "$PROJECT_NAME_TAG-sg" \
        --description 'OpenCSUSM SSH only' --query GroupId --output text)
    # Saves the Security Group ID to the state file for later stages.
    save_value SECURITY_GROUP_ID "$SECURITY_GROUP_ID"
    # Tags the Security Group with relevant info for teardown.
    aws ec2 create-tags --region "$REGION" --resources "$SECURITY_GROUP_ID" --tags \
        Key=Name,Value="$PROJECT_NAME_TAG-sg" Key=Course,Value="$COURSE_TAG" \
        Key=Owner,Value="$OWNER_TAG" Key=Lab,Value="$LAB_TAG" Key=Project,Value=OpenCSUSM
    # Authorizes SSH ingress from the current laptop's IP address.
    aws ec2 authorize-security-group-ingress --region "$REGION" \
        --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr "$MYIP/32"

    # Launches the EC2 instance in our custom public subnet.
    INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
        --image-id "$AMI" --instance-type "$INSTANCE" --key-name "$KEYNAME" \
        --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SECURITY_GROUP_ID,AssociatePublicIpAddress=true" \
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_NAME_TAG-instance},{Key=Course,Value=$COURSE_TAG},{Key=Project,Value=OpenCSUSM},{Key=Owner,Value=$OWNER_TAG},{Key=Lab,Value=$LAB_TAG}]" \
        --query 'Instances[0].InstanceId' --output text)
    # Saves the EC2 instance ID to the state file for later stages.
    save_value INSTANCE_ID "$INSTANCE_ID"
    echo "Instance launched: $INSTANCE_ID"
    # Waits until the EC2 instance is in the running state.
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
    # Retrieves the public DNS name of the running EC2 instance.
    DNS=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
    echo "SSH: ssh -i \"$KEY_FILE\" $SSH_USER@$DNS"
    echo "Compute billing has started at the selected instance rate."
    ;;

# --- 3 ------------------------------------- Install Ollama over SSH
3)
    echo "== Stage 3: Installing Ollama on EC2 ==========================="

    # Retrieves the instance ID saved by Stage 2.
    [[ -s "$STATE" ]] || {
        echo "No instance state; complete Stage 2 first." >&2
        exit 1
    }
    source "$STATE"
    ID="${INSTANCE_ID:?No EC2 instance recorded}"

    # Retrieves the public DNS hostname of the EC2 instance.
    DNS=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' \
        --output text)

    # Checks if SSH is ready before installing Ollama.
    echo "Checking if SSH is ready on $DNS..."
    READY=0

    for attempt in $(seq 1 24); do
        if ssh -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=5 \
            -i "$KEY_FILE" \
            "$SSH_USER@$DNS" 'echo SSH ready' 2>/dev/null; then
            READY=1
            break
        fi
        sleep 15
    done

    # Stops Stage 3 if SSH connection is unavailable.
    if [[ "$READY" != "1" ]]; then
        echo "SSH not ready; retry Stage 3."
        exit 1
    fi

    # Connects over SSH, installs Ollama, and verifies its service.
    echo "SSH ready. Installing Ollama..."
    ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -i "$KEY_FILE" \
        "$SSH_USER@$DNS" \
        'set -e; curl -fsSL https://ollama.com/install.sh | sh; sudo systemctl enable --now ollama; systemctl is-active ollama; nproc'

    echo "Stage 3 completed. Ollama installed."
    ;;

# --- 4 ------------------------------------------- ON THE INSTANCE: serve it
4)
    echo "== Stage 4: Loading model $MODEL ==============================="

    # Retrieves the EC2 instance ID saved by Stage 2.
    [[ -s "$STATE" ]] || {
        echo "No instance state; complete Stage 2 first." >&2
        exit 1
    }
    source "$STATE"
    ID="${INSTANCE_ID:?No EC2 instance recorded}"

    # Retrieves the EC2 public DNS hostname.
    DNS=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' \
        --output text)

    # Connects through SSH, downloads the model, and checks Ollama.
    echo "Connecting to EC2 and downloading model..."
    ssh -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        -i "$KEY_FILE" \
        "$SSH_USER@$DNS" \
        "set -e; ollama pull '$MODEL'; ollama list; curl -fsS http://127.0.0.1:$PORT/v1/models"

    echo "Stage 4 completed. Model $MODEL is available."
    ;;

# --- 5 -------------------------------------------- ON YOUR LAPTOP: the tunnel
5)
    source "$STATE"
    ID="${INSTANCE_ID:?Missing instance ID in state file}"
    DNS=$(aws ec2 describe-instances --region "$REGION" \
        --instance-ids "$ID" \
        --query 'Reservations[0].Instances[0].PublicDnsName' --output text)
    echo "== Open the tunnel in a SECOND terminal, and leave it running ========"
    echo
    echo "   ssh -o ExitOnForwardFailure=yes -i \"$KEY_FILE\" -N -L 127.0.0.1:$PORT:127.0.0.1:$PORT $SSH_USER@$DNS"
    echo
    echo "   Port $PORT on your laptop now reaches the model, and nobody else can."
    ;;

# --- 6 --------------------------------------------------------- the real test
6)
    echo "== The test that must pass ($MODE path) ============================"
    # 'localhost' below is your laptop, not the instance. Stage 5's tunnel opened
    # this port here and carries it, inside the ssh connection, to the same port
    # on the box. Every byte travels over port 22 - the only port the security
    # group ever opens - so the model is never reachable from the internet.
    # No tunnel running in a second terminal => 'Could not connect to server'.
    curl -fsS --max-time 120 "http://127.0.0.1:$PORT/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\": \"$MODEL\",
         \"messages\": [
           {\"role\": \"system\",
            \"content\": \"Greet the user by name. Reply with the greeting only.\"},
           {\"role\": \"user\", \"content\": \"I am John\"}
         ],
         \"max_tokens\": 20, \"temperature\": 0}" |
        python3 -c "import json,sys;d=json.load(sys.stdin);\
    print('   reply:', d['choices'][0]['message']['content'].strip());\
    print('   tokens:', d.get('usage'))"
    echo
    echo "   A reply containing 'John' is a pass. Paste it into this file."
    ;;

# --- 7 ------------------------------------------------------------------ stop
7)
    # Stops the EC2 instance to halt compute billing. The attached storage continues to incur costs.
    # Uses the instance ID from the state file to stop the instance.
    source "$STATE"
    ID="${INSTANCE_ID:?Missing instance ID in state file}"
    aws ec2 stop-instances --region "$REGION" --instance-ids "$ID" \
        --query 'StoppingInstances[0].CurrentState.Name' --output text
    echo "   Compute billing stops. The ${DISK} GB gp3 volume still costs about"
    echo "   \$$(python3 -c "print(round($DISK*0.08,2))") a month until stage 8."
    ;;

# --- 8 ---------------------------------------------------------------- delete
8)
    [[ -s "$STATE" ]] || {
        echo "No state file: $STATE" >&2
        exit 1
    }
    source "$STATE"

    # Deletes only if resources were created and recorded executing this script.
    # Checks and deletes EC2 Instances if they exist.
    if [[ -n "${INSTANCE_ID:-}" ]]; then
        echo "Terminating $INSTANCE_ID"
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
    fi
    # Checks and deletes Security Groups if they exist.
    if [[ -n "${SECURITY_GROUP_ID:-}" ]]; then
        aws ec2 delete-security-group --region "$REGION" --group-id "$SECURITY_GROUP_ID"
    fi
    # Checks and disassociates Route Table if an association exists.
    if [[ -n "${ROUTE_ASSOCIATION_ID:-}" ]]; then
        aws ec2 disassociate-route-table --region "$REGION" --association-id "$ROUTE_ASSOCIATION_ID"
    fi
    # Checks and deletes Subnet if it exists.
    if [[ -n "${SUBNET_ID:-}" ]]; then
        aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID"
    fi
    # Checks and deletes Route Table if it exists.
    if [[ -n "${ROUTE_TABLE_ID:-}" ]]; then
        aws ec2 delete-route-table --region "$REGION" --route-table-id "$ROUTE_TABLE_ID"
    fi
    # Checks and deletes Internet Gateway if it exists.
    if [[ -n "${IGW_ID:-}" ]]; then
        aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
        aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID"
    fi
    # Checks and deletes VPC if it exists.
    if [[ -n "${VPC_ID:-}" ]]; then
        aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
    fi
    # The pre-existing AWS key pair is deliberately retained.
    rm -f "$STATE"
    echo "Stage 8 complete: this run's EC2 and custom network were removed."
    ;;

*)
    echo "unknown stage: $stage"
    exit 2
    ;;
esac

# =============================================================================
#  PASTE YOUR STAGE 6 OUTPUT BELOW THIS LINE
#  == The test that must pass (cpu path) ============================
#   reply: Hello, John.
#   tokens: {'prompt_tokens': 29, 'prompt_tokens_details': {'cached_tokens': 0}, 'completion_tokens': 5, 'total_tokens': 34}
#
#   A reply containing 'John' is a pass. Paste it into this file.
#   stopping
#   Compute billing stops. The 40 GB gp3 volume still costs about
#   $3.2 a month until stage 8.
#
#  mode (gpu/cpu): $3.2 a month         why: less expensive and worked for Qwen 0.5B
#  instance:   m7i-flex.large           model: qwen2.5:0.5b
#  reply: Hello, John.
#  hours running: 5 minutes             estimated cost: $0.00798
# =============================================================================
