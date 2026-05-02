# AdvoHQ Backend — Setup & Deployment Guide

## Architecture

```
Browser (HTML pages)
       │
       ▼
  Vercel Edge
  ├── /public/*      ← Your HTML frontend files
  └── /api/*         ← Serverless Node.js handlers
             │
             ├── AWS RDS PostgreSQL  ← Data (cases, users, events)
             └── AWS S3              ← Files (briefs, petitions, evidence)
```

---

## 1. Prerequisites

- Node.js 18+
- Vercel CLI: `npm i -g vercel`
- AWS Account with IAM access
- (Optional) Terraform for infra provisioning

---

## 2. AWS Setup

### Option A — Terraform (recommended)
```bash
cd infra/
terraform init
terraform apply -var="db_password=YourSecurePassword123!"
# Copy the outputs: rds_endpoint, iam_access_key_id, iam_secret_access_key, s3_bucket_name
```

### Option B — Manual via AWS Console

**RDS (PostgreSQL):**
1. Go to RDS → Create database
2. Engine: PostgreSQL 16
3. Template: Free tier (dev) or Production
4. DB instance ID: `advohq-db`
5. Master username: `advohq_admin`, set a strong password
6. DB name: `advohq`
7. Enable public access → Yes (for Vercel connectivity)
8. Add security group rule: inbound TCP 5432 from `0.0.0.0/0`
9. Enable automated backups, encryption

**S3:**
1. Create bucket `advohq-files-<unique>`
2. Block all public access → ON
3. Enable versioning, server-side encryption (AES-256)
4. Add CORS rule (see `infra/main.tf` for the exact config)

**IAM:**
1. Create user `advohq-vercel-api`
2. Attach inline policy with `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:HeadObject` on `arn:aws:s3:::advohq-files-*/*`
3. Create access key → save the Key ID and Secret

---

## 3. Local Development

```bash
# Install dependencies
npm install

# Copy and fill environment variables
cp .env.example .env.local
# → Edit .env.local with your RDS endpoint, S3 bucket, IAM keys, JWT secret

# Run database migrations
npm run migrate

# Seed demo data (optional)
npm run seed

# Start local dev server (Vercel CLI)
npm run dev
# → http://localhost:3000
```

---

## 4. Deploy to Vercel

```bash
# Login to Vercel
vercel login

# First deploy (follow prompts, link to your project)
vercel

# Set all environment variables in Vercel dashboard:
# Project → Settings → Environment Variables

# Required variables:
#   JWT_SECRET
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_SSL
#   AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET_NAME
#   APP_URL  (e.g. https://advohq.vercel.app)

# Production deploy
vercel --prod
```

---

## 5. Connecting Frontend to Backend

Add this to your HTML files (before `</body>`):

```html
<script src="/js/api.js"></script>
<script>
  // Check auth on protected pages
  if (!api.requireAuth()) return;

  // Load dashboard data
  api.getDashboard().then(data => {
    console.log('Active cases:', data.cases.active);
    console.log('Upcoming events:', data.upcoming_events);
  });
</script>
```

**Login page integration (`login2.html`):**
```html
<script src="/js/api.js"></script>
<script>
  document.querySelector('.btn-primary').onclick = async () => {
    const username = document.querySelector('input[autocomplete="username"]').value;
    const password = document.querySelector('input[autocomplete="current-password"]').value;
    try {
      await api.login(username, password);
      window.location.href = '/advohq-home.html';
    } catch (err) {
      alert(err.message);
    }
  };
</script>
```

---

## 6. API Reference

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/auth/login` | Login, returns JWT |
| POST | `/api/auth/register` | Register new user |
| GET | `/api/auth/me` | Get current user profile |
| GET | `/api/dashboard` | Stats + upcoming events |
| GET | `/api/cases` | List cases (filterable) |
| POST | `/api/cases` | Create a new case |
| GET | `/api/cases/:id` | Get case + notes + files |
| PATCH | `/api/cases/:id` | Update case fields |
| DELETE | `/api/cases/:id` | Archive a case |
| GET | `/api/files?case_id=` | List files for a case |
| POST | `/api/files` | Request S3 upload URL |
| GET | `/api/files/:id` | Get download URL |
| DELETE | `/api/files/:id` | Delete a file |
| GET | `/api/schedule` | List events |
| POST | `/api/schedule` | Create an event |
| PATCH | `/api/schedule/:id` | Update event |
| DELETE | `/api/schedule/:id` | Delete event |
| GET | `/api/users/:id` | Get user profile |
| PATCH | `/api/users/:id` | Update profile / password |
| GET | `/api/health` | Health check (DB ping) |

All authenticated endpoints require: `Authorization: Bearer <token>`

---

## 7. Security Checklist

- [ ] JWT_SECRET is at least 32 random characters
- [ ] RDS is NOT publicly accessible in production (use VPC + Vercel private networking)
- [ ] S3 bucket public access is fully blocked
- [ ] IAM user has minimal S3 permissions (only the `cases/*` prefix)
- [ ] DB password is strong (16+ chars, mixed case, numbers, symbols)
- [ ] DB_SSL=true in production
- [ ] Enable AWS CloudTrail for audit logging
- [ ] Set up Vercel firewall rules to rate-limit `/api/auth/*`

---

## 8. Database Schema Overview

| Table | Purpose |
|-------|---------|
| `users` | Advocates, paralegals, admins |
| `cases` | Case records with court & client info |
| `case_members` | Many-to-many: users assigned to cases |
| `case_notes` | Internal notes per case |
| `case_files` | File metadata (bytes in S3) |
| `schedule_events` | Hearings, deadlines, meetings |
| `audit_log` | Immutable action log |

---

## 9. Project Structure

```
advohq-backend/
├── api/
│   ├── auth/
│   │   ├── login.js         POST /api/auth/login
│   │   ├── register.js      POST /api/auth/register
│   │   └── me.js            GET  /api/auth/me
│   ├── cases/
│   │   ├── index.js         GET|POST /api/cases
│   │   └── [id].js          GET|PUT|DELETE /api/cases/:id
│   ├── files/
│   │   ├── index.js         GET|POST /api/files
│   │   └── [id].js          GET|DELETE /api/files/:id
│   ├── schedule/
│   │   ├── index.js         GET|POST /api/schedule
│   │   └── [id].js          GET|PUT|DELETE /api/schedule/:id
│   ├── users/
│   │   └── [id].js          GET|PATCH /api/users/:id
│   ├── dashboard.js         GET /api/dashboard
│   └── health.js            GET /api/health
├── lib/
│   ├── db.js               PostgreSQL pool
│   ├── auth.js             JWT helpers
│   ├── s3.js               AWS S3 helpers
│   └── helpers.js          CORS, response utils
├── migrations/
│   ├── 001_schema.sql      Full DB schema
│   ├── run.js              Migration runner
│   └── seed.js             Demo data seeder
├── public/
│   └── js/api.js           Frontend API client
├── infra/
│   └── main.tf             Terraform (AWS RDS + S3 + IAM)
├── .env.example            Environment variable template
├── vercel.json             Vercel routing config
└── package.json
```
