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
# ORDEN EXACTO DE DESTRUCCIÓN (CONSISTENTE CON deploy.ps1 V2)
##############################################################

Remove-Stack -Name "$STACK_NAME-app"
Remove-Stack -Name "$STACK_NAME-bastion"
Remove-Stack -Name "$STACK_NAME-asg"
Remove-Stack -Name "$STACK_NAME-vpce"
Remove-Stack -Name "$STACK_NAME-alb"
Remove-Stack -Name "$STACK_NAME-vpc"

Write-Host "`nDESTRUCCIÓN COMPLETADA."
