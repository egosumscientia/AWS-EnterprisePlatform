#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$STACK_NAME = "aws-enterprise-platform"
$REGION = "us-east-1"

function Require-Success($Message) {
    if (-not $?) {
        Write-Host "ERROR: $Message"
        exit 1
    }
}

Write-Host "Validando CloudFormation templates..."

aws cloudformation validate-template --template-body file://cloudformation/vpc.yaml           | Out-Null
Require-Success "Validacion fallo en vpc.yaml"

aws cloudformation validate-template --template-body file://cloudformation/vpc-endpoint.yaml | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/alb.yaml          | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/asg.yaml          | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/ec2-bastion.yaml  | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/ec2-app.yaml      | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/rds.yaml          | Out-Null

Write-Host "Validacion OK.`n"


##############################################
# 1. AMI
##############################################

Write-Host "Obteniendo AMI Amazon Linux 2..."
$AMI_ID = aws ssm get-parameters `
    --names "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" `
    --region $REGION `
    --query "Parameters[0].Value" `
    --output text
Require-Success "No se pudo obtener AMI desde SSM"

Write-Host "AMI encontrada: $AMI_ID`n"


##############################################
# 2. AZs
##############################################

Write-Host "Obteniendo AZs disponibles..."
$AZ_LIST = aws ec2 describe-availability-zones `
    --region $REGION `
    --query "AvailabilityZones[].ZoneName" `
    --output text
Require-Success "No se pudieron obtener AZs"

$AZ_ARRAY = $AZ_LIST -split "\s+"
$AZ1 = $AZ_ARRAY[0]
$AZ2 = $AZ_ARRAY[1]

Write-Host "AZ1: $AZ1"
Write-Host "AZ2: $AZ2`n"


##############################################
# 3. VPC
##############################################

Write-Host "Aplicando stack VPC..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-vpc" `
    --template-file cloudformation/vpc.yaml `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides Az1=$AZ1 Az2=$AZ2

Require-Success "Fallo deploy de la VPC"

Write-Host "Obteniendo outputs de la VPC..."

$VpcJson = aws cloudformation describe-stacks `
    --region $REGION `
    --stack-name "$STACK_NAME-vpc" 2>$null

Require-Success "describe-stacks FALLO. No existe stack VPC."

$VpcOutputs = $VpcJson | ConvertFrom-Json

function Get-Output($Key) {
    $value = ($VpcOutputs.Stacks[0].Outputs |
        Where-Object { $_.OutputKey -ieq $Key }
    ).OutputValue

    if (-not $value) {
        Write-Host "ERROR: Output '$Key' no encontrado en la VPC."
        exit 1
    }
    return $value
}

$VPC_ID          = Get-Output "VpcId"
$PUBLIC_SUBNETS  = Get-Output "PublicSubnets"
$PRIVATE_SUBNETS = Get-Output "PrivateSubnets"
$PRIVATE_RT      = Get-Output "PrivateRouteTableId"

Write-Host "DEBUG: PRIVATE_RT='$PRIVATE_RT'"

$PUBLIC_SUBNET_1,  $PUBLIC_SUBNET_2   = $PUBLIC_SUBNETS  -split ","
$PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2  = $PRIVATE_SUBNETS -split ","

Write-Host "VPC ID: $VPC_ID"
Write-Host "Public Subnets: $PUBLIC_SUBNET_1 , $PUBLIC_SUBNET_2"
Write-Host "Private Subnets: $PRIVATE_SUBNET_1 , $PRIVATE_SUBNET_2"
Write-Host ""


##############################################
# 4. ALB
##############################################

Write-Host "Aplicando ALB..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-alb" `
    --template-file cloudformation/alb.yaml `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        VpcId=$VPC_ID `
        PublicSubnet1=$PUBLIC_SUBNET_1 `
        PublicSubnet2=$PUBLIC_SUBNET_2

Require-Success "Fallo deploy del ALB"

$AlbJson = aws cloudformation describe-stacks `
    --region $REGION `
    --stack-name "$STACK_NAME-alb" 2>$null
Require-Success "describe-stacks FALLÓ para ALB"

$AlbOutputs = $AlbJson | ConvertFrom-Json

$TG_ARN = ($AlbOutputs.Stacks[0].Outputs |
    Where-Object { $_.OutputKey -eq "TargetGroupArn" }
).OutputValue

$ALB_SG = ($AlbOutputs.Stacks[0].Outputs |
    Where-Object { $_.OutputKey -eq "AlbSecurityGroupId" }
).OutputValue

if (-not $TG_ARN -or -not $ALB_SG) {
    Write-Host "ERROR: Outputs del ALB incompletos."
    exit 1
}

Write-Host "Target Group ARN: $TG_ARN"
Write-Host "ALB Security Group: $ALB_SG`n"


##############################################
# 5. VPC ENDPOINTS
##############################################

Write-Host "Aplicando VPC Endpoints..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-vpce" `
    --template-file cloudformation/vpc-endpoint.yaml `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        VpcId=$VPC_ID `
        PrivateSubnet1=$PRIVATE_SUBNET_1 `
        PrivateSubnet2=$PRIVATE_SUBNET_2 `
        SecurityGroupId=$ALB_SG `
        PrivateRouteTableId=$PRIVATE_RT

Require-Success "Fallo deploy de VPCE"

Write-Host ""
Write-Host "VPC ENDPOINTS OK."
Write-Host ""


##############################################
# 6. ASG
##############################################

Write-Host "Aplicando ASG..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-asg" `
    --template-file cloudformation/asg.yaml `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        AmiId=$AMI_ID `
        VpcId=$VPC_ID `
        PrivateSubnet1=$PRIVATE_SUBNET_1 `
        PrivateSubnet2=$PRIVATE_SUBNET_2 `
        SecurityGroupEc2=$ALB_SG `
        TargetGroupArn=$TG_ARN `

Require-Success "Fallo deploy del ASG"

$AsgJson = aws cloudformation describe-stacks `
    --region $REGION `
    --stack-name "$STACK_NAME-asg" 2>$null
Require-Success "describe-stacks FALLO para ASG"

$AsgOutputs = $AsgJson | ConvertFrom-Json

$ASG_SG = ($AsgOutputs.Stacks[0].Outputs |
    Where-Object { $_.OutputKey -eq "AsgSecurityGroupId" }
).OutputValue

if (-not $ASG_SG) {
    Write-Host "ERROR: Output AsgSecurityGroupId no encontrado."
    exit 1
}

Write-Host "ASG Security Group: $ASG_SG"
Write-Host ""


##############################################
# 7. BASTION
##############################################

Write-Host "Aplicando Bastion..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-bastion" `
    --template-file cloudformation/ec2-bastion.yaml `
    --parameter-overrides `
        AmiId=$AMI_ID `
        VpcId=$VPC_ID `
        PublicSubnetId=$PUBLIC_SUBNET_1 `

Require-Success "Fallo deploy del Bastion"

Write-Host "Bastion OK.`n"

$BastionJson = aws cloudformation describe-stacks `
    --region $REGION `
    --stack-name "$STACK_NAME-bastion" 2>$null
Require-Success "describe-stacks FALLÓ para Bastion"

$BastionOutputs = $BastionJson | ConvertFrom-Json

$BASTION_SG = ($BastionOutputs.Stacks[0].Outputs |
    Where-Object { $_.OutputKey -eq "BastionSecurityGroupId" }
).OutputValue

if (-not $BASTION_SG) {
    Write-Host "ERROR: BastionSecurityGroupId no encontrado."
    exit 1
}

Write-Host "Bastion Security Group: $BASTION_SG"
Write-Host ""


##############################################
# 8. APP SERVER
##############################################

Write-Host "Aplicando EC2 App..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-app" `
    --template-file cloudformation/ec2-app.yaml `
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        AmiId=$AMI_ID `
        VpcId=$VPC_ID `
        PrivateSubnetId=$PRIVATE_SUBNET_1 `
        SecurityGroupId=$ALB_SG `
        KeyName=aws-platform-key

Require-Success "Fallo deploy del App EC2"

$AppJson = aws cloudformation describe-stacks `
    --region $REGION `
    --stack-name "$STACK_NAME-app" 2>$null
Require-Success "describe-stacks FALLO para App"

$AppOutputs = $AppJson | ConvertFrom-Json

$APP_SG = ($AppOutputs.Stacks[0].Outputs |
    Where-Object { $_.OutputKey -eq "AppInstanceSecurityGroup" }
).OutputValue

if (-not $APP_SG) {
    Write-Host "ERROR: AppInstanceSecurityGroup no encontrado."
    exit 1
}

Write-Host "APP Security Group: $APP_SG"
Write-Host ""


##############################################
# 9. RDS
##############################################

Write-Host "Aplicando RDS..."

aws cloudformation deploy `
    --region $REGION `
    --stack-name "$STACK_NAME-rds" `
    --template-file cloudformation/rds.yaml `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        VpcId=$VPC_ID `
        PrivateSubnet1=$PRIVATE_SUBNET_1 `
        PrivateSubnet2=$PRIVATE_SUBNET_2 `
        SecurityGroupAsg=$ASG_SG `
        SecurityGroupApp=$APP_SG `
        SecurityGroupBastion=$BASTION_SG `
        DBPassword="Password123!"

Require-Success "Fallo deploy de RDS"

Write-Host ""
Write-Host "DEPLOY COMPLETADO."
Write-Host ""