#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$STACK_NAME = "aws-enterprise-platform"
$REGION = "us-east-1"

function Remove-Stack {
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )

    Write-Host "`nEliminando stack: $Name"

    aws cloudformation delete-stack `
        --stack-name $Name `
        --region $REGION

    Write-Host "Esperando eliminación completa de $Name..."
    aws cloudformation wait stack-delete-complete `
        --stack-name $Name `
        --region $REGION

    Write-Host "Stack eliminado: $Name"
}


##############################################################
# ORDEN EXACTO DE DESTRUCCIÓN (INCLUYE RDS)
##############################################################
# Este orden evita dependencias:
# - Instancias dependen de SG/VPC/Subnets
# - ASG depende de ALB y subnets
# - RDS depende de subnet group + subnets + SGs
# - VPCE depende de VPC + subnets
# - ALB depende de subnets
# - VPC siempre va de último

# 1. EC2 App
Remove-Stack -Name "$STACK_NAME-app"

# 2. Bastion
Remove-Stack -Name "$STACK_NAME-bastion"

# 3. Auto Scaling Group
Remove-Stack -Name "$STACK_NAME-asg"

# 4. RDS (se destruye aquí para que sus SGs no estén en uso)
Remove-Stack -Name "$STACK_NAME-rds"

# 5. VPC Endpoints
Remove-Stack -Name "$STACK_NAME-vpce"

# 6. ALB
Remove-Stack -Name "$STACK_NAME-alb"

# 7. VPC
Remove-Stack -Name "$STACK_NAME-vpc"


Write-Host "`nDESTRUCCIÓN COMPLETADA."
