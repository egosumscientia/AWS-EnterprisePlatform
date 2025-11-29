# AWS Enterprise Platform

Infraestructura modular en AWS utilizando CloudFormation, PowerShell y AWS CLI.

Este proyecto despliega una plataforma mínima de nivel empresarial compuesta por:

* VPC con subnets públicas y privadas
* NAT Gateway
* Application Load Balancer (ALB)
* Auto Scaling Group (ASG)
* EC2 Bastion host
* EC2 App individual
* VPC Endpoints (S3, DynamoDB, SSM)
* Scripts de despliegue y destrucción totalmente automatizados (PowerShell)

---

## 1. Arquitectura

### Componentes principales

| Componente         | Descripción                                                               |
| ------------------ | ------------------------------------------------------------------------- |
| **VPC**            | 1 VPC con 2 subnets públicas y 2 subnets privadas                         |
| **ALB**            | Public-facing, asociado a Target Group HTTP                               |
| **ASG**            | 2–4 instancias Amazon Linux 2 con Nginx                                   |
| **Bastion**        | EC2 pública con acceso SSH                                                |
| **App EC2**        | Instancia privada individual para pruebas                                 |
| **NAT Gateway**    | Para tráfico saliente de instancias privadas                              |
| **VPC Endpoints**  | Gateway (S3, DynamoDB) + Interface (SSM)                                  |
| **RDS PostgreSQL** | Instancia privada db.t3.micro, PostgreSQL 15.x, acceso solo desde SGs VPC |

---

## 2. Requisitos previos

1. AWS CLI configurado:

```powershell
aws configure
```

2. Verificación de identidad:

```powershell
aws sts get-caller-identity
```

3. PowerShell 5.1 o superior
4. Permisos IAM suficientes para EC2, ELB, ASG, CloudFormation y VPC
5. Proyecto con la siguiente estructura:

```
aws-enterprise-platform/
│
├─ cloudformation/
│   ├─ vpc.yaml
│   ├─ vpc-endpoint.yaml
│   ├─ alb.yaml
│   ├─ asg.yaml
│   ├─ ec2-bastion.yaml
│   ├─ ec2-app.yaml
│
├─ deploy.ps1
└─ destroy.ps1
```

---

## 3. Despliegue automatizado

Ejecutar desde PowerShell en la raíz:

```powershell
.\deploy.ps1
```

El script realiza automáticamente:

1. Validación de todas las plantillas

2. Obtención automática de la AMI Amazon Linux 2 desde SSM

3. Creación secuencial de los stacks:

   * `aws-enterprise-platform-vpc`
   * `aws-enterprise-platform-alb`
   * `aws-enterprise-platform-vpce`
   * `aws-enterprise-platform-asg`
   * `aws-enterprise-platform-bastion`
   * `aws-enterprise-platform-app`

4. Obtención de todos los outputs relevantes

5. Impresión de parámetros usados (VPC, Subnets, Target Group, Security Groups)

---

## 4. Verificación del despliegue

### 4.1. Obtener DNS del ALB

```powershell
aws cloudformation describe-stacks `
  --stack-name aws-enterprise-platform-alb `
  --query "Stacks[0].Outputs[?OutputKey=='AlbDnsName'].OutputValue" `
  --output text
```

Probar que responde:

```powershell
curl http://<ALB-DNS>
```

Debe devolver:

```
<h1>ASG - dev - Instancia OK</h1>
```

---

## 5. Destrucción completa

Para destruir toda la plataforma:

```powershell
.\destroy.ps1
```

El script elimina los stacks en orden correcto:

1. App
2. Bastion
3. ASG
4. VPC Endpoints
5. ALB
6. VPC

### Verificar que no queden stacks:

```powershell
aws cloudformation describe-stacks
```

### Verificar que no queden instancias EC2:

```powershell
aws ec2 describe-instances --query "Reservations[].Instances[].InstanceId"
```

---

## 6. Costos esperados

| Recurso                     | Aproximado mensual |
| --------------------------- | ------------------ |
| NAT Gateway                 | ~32 USD            |
| ALB                         | ~18 USD            |
| EC2 (4 instancias t3.micro) | ~30 USD            |
| VPC Endpoints               | 6–10 USD           |

**Total aprox:** 80–90 USD/mes
**Recomendación:** usar solo para pruebas y destruir inmediatamente.

---

## 7. Scripts incluidos

### deploy.ps1

* Automatiza el despliegue
* Obtiene AMI desde SSM
* No requiere intervención manual
* Totalmente idempotente

### destroy.ps1

* Limpia toda la infraestructura
* Maneja dependencias correctamente
* Evita recursos huérfanos

---

## 8. Base de datos RDS integrada

El proyecto incluye ahora una base de datos **Amazon RDS PostgreSQL** económica, privada y totalmente integrada con la VPC.

### Características:

* Motor: PostgreSQL 15.x
* Instancia: **db.t3.micro** (barata)
* Almacenamiento: 20 GB gp2
* Despliegue en **subnets privadas**
* Seguridad:

  * Acceso solo desde ASG, App EC2 y Bastion
  * No es pública
* Subnet Group automático
* Seguridad por SGs
* Compatible con los scripts de deploy/destroy

### Forma de conexión

Después del despliegue, obtener el endpoint:

```powershell
aws cloudformation describe-stacks `
  --stack-name aws-enterprise-platform-rds `
  --query "Stacks[0].Outputs[?OutputKey=='RdsEndpoint'].OutputValue" `
  --output text
```

Conectarse desde Bastion:

```bash
psql -h <endpoint> -U admin -d postgres
```

---

## 9. Licencia. Licencia

Este proyecto es de uso libre para fines educativos o empresariales básicos.

```
```
