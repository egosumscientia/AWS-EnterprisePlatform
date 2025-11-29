#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$STACK_PREFIX = "aws-enterprise-platform"
$REGION = "us-east-1"

##############################################
# FUNCIONES
##############################################

function Get-StackStatus {
    param([string]$Name)

    $json = aws cloudformation describe-stacks `
        --stack-name $Name `
        --region $REGION 2>$null

    if (-not $?) { return $null }

    ($json | ConvertFrom-Json).Stacks[0].StackStatus
}

function Show-Failures {
    param([string]$Name)

    Write-Host "`n[ERROR] Fallos recientes en ${Name}:"
    aws cloudformation describe-stack-events `
        --stack-name $Name `
        --region $REGION 2>$null |
        ConvertFrom-Json |
        Select-Object -ExpandProperty StackEvents |
        Where-Object { $_.ResourceStatus -like "*FAILED" } |
        Select-Object -First 10 Timestamp, ResourceType, LogicalResourceId, ResourceStatusReason |
        Format-Table -AutoSize

    Write-Host ""
}

function Stack-Exists {
    param([string]$Name)
    $status = Get-StackStatus -Name $Name
    return -not [string]::IsNullOrEmpty($status)
}

function Delete-Stack {
    param(
        [string]$Name,
        [int]$TimeoutMinutes = 10
    )

    Write-Host "`n=== Eliminando stack: $Name ==="

    if (-not (Stack-Exists -Name $Name)) {
        Write-Host "[SKIP] Stack no existe: $Name"
        return
    }

    # Intentar eliminar
    aws cloudformation delete-stack `
        --stack-name $Name `
        --region $REGION

    if (-not $?) {
        Write-Host "[ERROR] Fallo al iniciar eliminación de $Name"
        return
    }

    # Loop de monitoreo
    $iterations = $TimeoutMinutes * 6  # cada 10 segundos
    for ($i = 0; $i -lt $iterations; $i++) {
        Start-Sleep -Seconds 10

        $status = Get-StackStatus -Name $Name

        if ($null -eq $status) {
            Write-Host "[OK] $Name eliminado exitosamente."
            return
        }

        # Mostrar progreso cada minuto
        if ($i % 6 -eq 0) {
            $elapsed = [math]::Floor($i / 6)
            Write-Host "[$elapsed min] $Name => $status"
        }

        if ($status -eq "DELETE_FAILED") {
            Write-Host "[ERROR] DELETE_FAILED en $Name"
            Show-Failures -Name $Name
            
            # Preguntar si continuar
            Write-Host "`n¿Intentar forzar eliminación? (s/n)"
            $response = Read-Host
            if ($response -eq "s") {
                Write-Host "Reintentando eliminación..."
                aws cloudformation delete-stack `
                    --stack-name $Name `
                    --region $REGION
                continue
            } else {
                exit 1
            }
        }
    }

    Write-Host "[TIMEOUT] $Name tardó más de $TimeoutMinutes minutos."
    Show-Failures -Name $Name
    Write-Host "Estado actual: $(Get-StackStatus -Name $Name)"
    exit 1
}

function Disable-RDS-Protection {
    Write-Host "`n=== Verificando protección de RDS ==="
    
    $dbInstances = aws rds describe-db-instances `
        --region $REGION 2>$null |
        ConvertFrom-Json |
        Select-Object -ExpandProperty DBInstances |
        Where-Object { $_.DBInstanceIdentifier -like "*$STACK_PREFIX*" }

    foreach ($db in $dbInstances) {
        $dbId = $db.DBInstanceIdentifier
        if ($db.DeletionProtection) {
            Write-Host "Desactivando protección en: $dbId"
            aws rds modify-db-instance `
                --db-instance-identifier $dbId `
                --no-deletion-protection `
                --apply-immediately `
                --region $REGION | Out-Null
            
            if ($?) {
                Write-Host "[OK] Protección desactivada"
                Start-Sleep -Seconds 5
            }
        } else {
            Write-Host "[OK] No hay instancias RDS con protección activa"
        }
    }
}

function Clean-OrphanENIs {
    param([string]$VpcId)
    
    Write-Host "`n=== Limpiando ENIs huérfanos en VPC ==="
    
    $enis = aws ec2 describe-network-interfaces `
        --filters "Name=vpc-id,Values=$VpcId" `
        --region $REGION 2>$null |
        ConvertFrom-Json |
        Select-Object -ExpandProperty NetworkInterfaces |
        Where-Object { $_.Status -eq "available" }

    if (-not $enis -or $enis.Count -eq 0) {
        Write-Host "[OK] No hay ENIs huérfanos"
        return
    }

    foreach ($eni in $enis) {
        $eniId = $eni.NetworkInterfaceId
        Write-Host "Eliminando ENI huérfano: $eniId"
        aws ec2 delete-network-interface `
            --network-interface-id $eniId `
            --region $REGION 2>$null
        
        if ($?) {
            Write-Host "[OK] ENI eliminado"
        }
    }
}

function Get-VpcId {
    if (-not (Stack-Exists -Name "$STACK_PREFIX-vpc")) {
        return $null
    }

    $vpcJson = aws cloudformation describe-stacks `
        --stack-name "$STACK_PREFIX-vpc" `
        --region $REGION 2>$null

    if (-not $?) { return $null }

    $outputs = ($vpcJson | ConvertFrom-Json).Stacks[0].Outputs
    $vpcId = ($outputs | Where-Object { $_.OutputKey -eq "VpcId" }).OutputValue
    
    return $vpcId
}

##############################################
# ORDEN DE DESTRUCCIÓN
##############################################

$ORDER = @(
    @{ Name = "$STACK_PREFIX-rds";     Timeout = 15 },
    @{ Name = "$STACK_PREFIX-app";     Timeout = 10 },
    @{ Name = "$STACK_PREFIX-bastion"; Timeout = 10 },
    @{ Name = "$STACK_PREFIX-asg";     Timeout = 10 },
    @{ Name = "$STACK_PREFIX-vpce";    Timeout = 15 },
    @{ Name = "$STACK_PREFIX-alb";     Timeout = 10 },
    @{ Name = "$STACK_PREFIX-vpc";     Timeout = 20 }
)

##############################################
# EJECUCIÓN DEL DESTROY
##############################################

Write-Host "`n╔════════════════════════════════════════╗"
Write-Host "║  INICIANDO DESTRUCCIÓN DE STACKS       ║"
Write-Host "╚════════════════════════════════════════╝"

# Paso 1: Desactivar protección de RDS
Disable-RDS-Protection

# Paso 2: Obtener VPC ID antes de eliminar
$vpcId = Get-VpcId
if ($vpcId) {
    Write-Host "`nVPC ID detectado: $vpcId"
}

# Paso 3: Eliminar stacks en orden
foreach ($stack in $ORDER) {
    Delete-Stack -Name $stack.Name -TimeoutMinutes $stack.Timeout
}

# Paso 4: Limpiar ENIs huérfanos si la VPC aún existe
if ($vpcId) {
    Clean-OrphanENIs -VpcId $vpcId
    
    # Reintentar VPC si falló
    if (Stack-Exists -Name "$STACK_PREFIX-vpc") {
        Write-Host "`n[RETRY] Reintentando eliminación de VPC..."
        Delete-Stack -Name "$STACK_PREFIX-vpc" -TimeoutMinutes 20
    }
}

Write-Host "`n╔════════════════════════════════════════╗"
Write-Host "║  DESTRUCCIÓN COMPLETADA                ║"
Write-Host "╚════════════════════════════════════════╝`n"