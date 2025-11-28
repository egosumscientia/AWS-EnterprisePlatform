#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$STACK_NAME = "aws-enterprise-platform"
$REGION = "us-east-1"

Write-Host "Validando CloudFormation templates..."

aws cloudformation validate-template --template-body file://cloudformation/vpc.yaml           | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/vpc-endpoint.yaml | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/alb.yaml           | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/asg.yaml           | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/ec2-bastion.yaml   | Out-Null
aws cloudformation validate-template --template-body file://cloudformation/ec2-app.yaml       | Out-Null

Write-Host "Validación OK.`n"


##############################################
# 1. Obtener AMI Amazon Linux 2 automáticamente
##############################################

Write-Host "Obteniendo AMI Amazon Linux 2 desde SSM..."

$AMI_ID = aws ssm get-parameters `
    --names "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2" `
    --region $REGION `
    --query "Parameters[0].Value" `
    --output text

Write-Host "AMI encontrada: $AMI_ID`n"


##############################################
# 2. Obtener automáticamente 2 Availability Zones
##############################################

Write-Host "Obteniendo AZs disponibles..."

$AZ_LIST = aws ec2 describe-availability-zones `
    --region $REGION `
    --query "AvailabilityZones[].ZoneName" `
    --output text

$AZ_ARRAY = $AZ_LIST -split "\s+"

$AZ1 = $AZ_ARRAY[0]
$AZ2 = $AZ_ARRAY[1]

Write-Host "AZ1 seleccionada: $AZ1"
Write-Host "AZ2 seleccionada: $AZ2`n"


##############################################
# 3. DEPLOY VPC
##############################################

Write-Host "Aplicando stack VPC..."
aws cloudformation deploy `
    --stack-name "$STACK_NAME-vpc" `
    --template-file cloudformation/vpc.yaml `
    --region $REGION `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        Az1=$AZ1 `
        Az2=$AZ2

Write-Host "Obteniendo outputs de la VPC..."

$VpcOutputs = aws cloudformation describe-stacks `
    --stack-name "$STACK_NAME-vpc" `
    --region $REGION `
    | ConvertFrom-Json

$VPC_ID = ($VpcOutputs.Stacks[0].Outputs | Where-Object {$_.OutputKey -eq "VpcId"}).OutputValue
$PUBLIC_SUBNETS = ($VpcOutputs.Stacks[0].Outputs | Where-Object {$_.OutputKey -eq "PublicSubnets"}).OutputValue
$PRIVATE_SUBNETS = ($VpcOutputs.Stacks[0].Outputs | Where-Object {$_.OutputKey -eq "PrivateSubnets"}).OutputValue

$PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2 = $PUBLIC_SUBNETS -split ","
$PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2 = $PRIVATE_SUBNETS -split ","

Write-Host "VPC ID: $VPC_ID"
Write-Host "Public Subnets: $PUBLIC_SUBNET_1 , $PUBLIC_SUBNET_2"
Write-Host "Private Subnets: $PRIVATE_SUBNET_1 , $PRIVATE_SUBNET_2"
Write-Host ""


##############################################
# 4. DEPLOY ALB
##############################################

Write-Host "Aplicando ALB..."
aws cloudformation deploy `
    --stack-name "$STACK_NAME-alb" `
    --template-file cloudformation/alb.yaml `
    --region $REGION `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        VpcId=$VPC_ID `
        PublicSubnet1=$PUBLIC_SUBNET_1 `
        PublicSubnet2=$PUBLIC_SUBNET_2

$AlbOutputs = aws cloudformation describe-stacks `
    --stack-name "$STACK_NAME-alb" `
    --region $REGION `
    | ConvertFrom-Json

$TG_ARN = ($AlbOutputs.Stacks[0].Outputs | Where-Object {$_.OutputKey -eq "TargetGroupArn"}).OutputValue
$ALB_SG = ($AlbOutputs.Stacks[0].Outputs | Where-Object {$_.OutputKey -eq "AlbSecurityGroupId"}).OutputValue

Write-Host "Target Group ARN: $TG_ARN"
Write-Host "ALB Security Group: $ALB_SG"
Write-Host ""


##############################################
# 5. DEPLOY VPC ENDPOINTS
##############################################

Write-Host "Aplicando VPC Endpoints..."
aws cloudformation deploy `
    --stack-name "$STACK_NAME-vpce" `
    --template-file cloudformation/vpc-endpoint.yaml `
    --region $REGION `
    --parameter-overrides `
        VpcId=$VPC_ID `
        PrivateSubnet1=$PRIVATE_SUBNET_1 `
        PrivateSubnet2=$PRIVATE_SUBNET_2 `
        SecurityGroupId=$ALB_SG

Write-Host ""


##############################################
# 6. DEPLOY ASG
##############################################

Write-Host "Aplicando ASG..."
aws cloudformation deploy `
    --stack-name "$STACK_NAME-asg" `
    --template-file cloudformation/asg.yaml `
    --region $REGION `
    --capabilities CAPABILITY_NAMED_IAM `
    --parameter-overrides `
        AmiId=$AMI_ID `
        PrivateSubnet1=$PRIVATE_SUBNET_1 `
        PrivateSubnet2=$PRIVATE_SUBNET_2 `
        SecurityGroupEc2=$ALB_SG `
        TargetGroupArn=$TG_ARN

Write-Host ""


##############################################
# 7. DEPLOY BASTION
##############################################

Write-Host "Aplicando Bastion..."
aws cloudformation deploy `
    --stack-name "$STACK_NAME-bastion" `
    --template-file cloudformation/ec2-bastion.yaml `
    --region $REGION `
    --parameter-overrides `
        AmiId=$AMI_ID `
        VpcId=$VPC_ID `
        PublicSubnetId=$PUBLIC_SUBNET_1

Write-Host ""


##############################################
# 8. DEPLOY APP EC2
##############################################

Write-Host "Aplicando EC2 App..."
aws cloudformation deploy `
    --stack-name "$STACK_NAME-app" `
    --template-file cloudformation/ec2-app.yaml `
    --region $REGION `
    --parameter-overrides `
        AmiId=$AMI_ID `
        VpcId=$VPC_ID `
        PrivateSubnetId=$PRIVATE_SUBNET_1 `
        SecurityGroupId=$ALB_SG

Write-Host ""
Write-Host "DEPLOY COMPLETADO."
