#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$STACK_NAME = "aws-enterprise-platform"
$REGION     = "us-east-1"

function Require-Success($Message) {
    if (-not $?) {
        Write-Host "ERROR: $Message"
        exit 1
    }
}

function Kill-ASG-Instances {
    Write-Host "`n--- Deteniendo ASG e instancias ---"

    $asgName = "$STACK_NAME-asg"

    # 1. Escala el ASG a 0
    aws autoscaling update-auto-scaling-group `
        --auto-scaling-group-name $asgName `
        --min-size 0 `
        --max-size 0 `
        --desired-capacity 0 `
        --region $REGION | Out-Null

    Start-Sleep -Seconds 5

    # 2. Obtener instancias del ASG
    $instances = aws autoscaling describe-auto-scaling-instances `
        --region $REGION `
        --query "AutoScalingInstances[].InstanceId" `
        --output text

    if ($instances) {
        Write-Host "Eliminando instancias del ASG: $instances"

        aws ec2 terminate-instances `
            --instance-ids $instances `
            --region $REGION | Out-Null
    }

    Write-Host "--- ASG e instancias detenidas ---`n"
}

function Kill-ENIs {
    Write-Host "`n--- Eliminando ENIs huérfanos ---"

    $enis = aws ec2 describe-network-interfaces `
        --region $REGION `
        --query "NetworkInterfaces[?Status=='in-use'].NetworkInterfaceId" `
        --output text

    foreach ($eni in $enis) {
        Write-Host "Forzando eliminación ENI: $eni"
        aws ec2 delete-network-interface `
            --network-interface-id $eni `
            --region $REGION 2>$null
    }

    Write-Host "--- ENIs procesados ---`n"
}

function Remove-Stack {
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )

    Write-Host "`nEliminando stack: $Name"

    aws cloudformation delete-stack `
        --stack-name $Name `
        --region $REGION

    Kill-ENIs

    aws cloudformation wait stack-delete-complete `
        --stack-name $Name `
        --region $REGION

    Write-Host "Stack eliminado: $Name"
}


##############################################
# ORDEN CORRECTO DE ELIMINACIÓN
##############################################

# 0. Parar ASG antes que cualquier cosa
Kill-ASG-Instances

# 1. EC2 App
Remove-Stack -Name "$STACK_NAME-app"

# 2. Bastion
Remove-Stack -Name "$STACK_NAME-bastion"

# 3. ASG
Remove-Stack -Name "$STACK_NAME-asg"

# 4. RDS
Remove-Stack -Name "$STACK_NAME-rds"

# 5. VPCE
Remove-Stack -Name "$STACK_NAME-vpce"

# 6. ALB
Remove-Stack -Name "$STACK_NAME-alb"

# 7. VPC
Remove-Stack -Name "$STACK_NAME-vpc"

Write-Host "`nDESTRUCCION COMPLETADA."
