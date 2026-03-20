# ADR-004 — Container Build & Deployment
**Date:** 2025-03-20
**Status:** Accepted

---

## Local Validation

```bash
# From repo root — build and run everything
docker compose -f hackathon/submissions/team1_contoso-cloud-migration/docker-compose.yml up --build

# Verify
curl http://localhost:8001/health   # backend
curl http://localhost:8080/health   # frontend
curl http://localhost:9000/minio/health/live  # S3 equivalent
```

---

## Cloud Deployment Path (AWS ECS Fargate)

The exact same images, zero changes, deploy to ECS.

### Step 1 — Push images to ECR

```bash
AWS_ACCOUNT=123456789012
AWS_REGION=ap-southeast-1

# Authenticate
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS \
    --password-stdin $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

# Tag and push backend
docker tag contoso-backend:latest \
  $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/contoso-backend:latest
docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/contoso-backend:latest

# Tag and push frontend
docker tag contoso-frontend:latest \
  $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/contoso-frontend:latest
docker push $AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com/contoso-frontend:latest
```

### Step 2 — ECS Task Definition (backend excerpt)

```json
{
  "family": "contoso-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/contoso-backend:latest",
      "portMappings": [{ "containerPort": 8001 }],
      "environment": [
        { "name": "DB_HOST", "value": "contoso.cluster-xyz.ap-southeast-1.rds.amazonaws.com" }
      ],
      "secrets": [
        { "name": "DB_PASSWORD", "valueFrom": "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:contoso/db-password" }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8001/health || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/contoso-backend",
          "awslogs-region": "ap-southeast-1",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
```

### Step 3 — Deploy service

```bash
aws ecs update-service \
  --cluster contoso-prod \
  --service contoso-backend \
  --force-new-deployment \
  --region ap-southeast-1
```

---

## Multi-stage Build Benefits

| Feature | Benefit |
|---|---|
| Builder stage separated from runtime | Final image contains no build tools (pip, gcc) — smaller attack surface |
| `python:3.12-slim` base | ~50MB vs ~900MB for full python image |
| Non-root user (`appuser`) | Container cannot write to host filesystem even if compromised |
| Health check endpoint | ECS marks task unhealthy and replaces it automatically |
| Secrets via AWS Secrets Manager | No secrets in image layers or environment variable plaintext |
