#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$STACK_PREFIX = "aws-enterprise-platform"
$REGION       = "us-east-1"

function Stack-Exists {
    param([string]$Name)
    $result = aws cloudformation describe-stacks `
        --stack-name $Name `
        --region $REGION 2>$null
    return $?
}

function Wait-Deletion {
    param([string]$Name)
    Write-Host "Esperando eliminación de: $Name"
    aws cloudformation wait stack-delete-complete `
        --stack-name $Name `
        --region $REGION
}

function Delete-Stack {
    param([string]$Name)

    if (Stack-Exists -Name $Name) {
        Write-Host "`n=== Eliminando stack: $Name ==="
        aws cloudformation delete-stack `
            --stack-name $Name `
            --region $REGION
        Wait-Deletion -Name $Name
        Write-Host "=== Stack eliminado: $Name ==="
    }
    else {
        Write-Host "`nStack no existe: $Name (omitido)"
    }
}

function Drain-ASG {
    $asgName = "$STACK_PREFIX-asg"
    Write-Host "`nDrenando ASG: $asgName"

    aws autoscaling update-auto-scaling-group `
        --auto-scaling-group-name $asgName `
        --min-size 0 `
        --max-size 0 `
        --desired-capacity 0 `
        --region $REGION 2>$null

    if (-not $?) { $Error.Clear() }

    Start-Sleep -Seconds 10
}

# ORDEN CORRECTO, INFALIBLE
Drain-ASG

$ORDER = @(
    "$STACK_PREFIX-asg",
    "$STACK_PREFIX-app",
    "$STACK_PREFIX-bastion",
    "$STACK_PREFIX-alb",
    "$STACK_PREFIX-vpce",
    "$STACK_PREFIX-rds",
    "$STACK_PREFIX-vpc"
)

foreach ($stack in $ORDER) {
    Delete-Stack -Name $stack
}

Write-Host "`n=== DESTRUCCIÓN COMPLETADA ==="
