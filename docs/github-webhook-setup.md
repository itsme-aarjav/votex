# GitHub Webhook to Jenkins Integration Guide

This guide walks you through setting up automated CI/CD triggers so every `git push` to your GitHub repository triggers the Jenkins pipeline automatically.

---

## 1. Prerequisites
- A running Jenkins instance with the **GitHub Integration Plugin** installed.
- Publicly accessible Jenkins URL (or ngrok / AWS EC2 public IP): `http://<YOUR_JENKINS_IP_OR_DOMAIN>:8080`

---

## 2. Configuring Jenkins Job
1. In Jenkins dashboard, click **New Item** $\rightarrow$ Select **Pipeline**.
2. Name the project: `votex-ci-cd`.
3. Under **Build Triggers**, check:
   - `[x] GitHub hook trigger for GITScm polling`
4. Under **Pipeline**:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/itsme-aarjav/votex.git`
   - Branch Specifier: `*/main`
   - Script Path: `Jenkinsfile`
5. Click **Save**.

---

## 3. Configuring Webhook in GitHub Repository
1. Open your repository on GitHub: [https://github.com/itsme-aarjav/votex](https://github.com/itsme-aarjav/votex)
2. Go to **Settings** $\rightarrow$ **Webhooks** $\rightarrow$ Click **Add webhook**.
3. Fill in the following fields:
   - **Payload URL**: `http://<YOUR_JENKINS_IP>:8080/github-webhook/` *(Notice the trailing slash!)*
   - **Content type**: `application/json`
   - **Secret**: *(Optional: Enter a secret string and configure the same in Jenkins GitHub plugin)*
   - **Which events would you like to trigger this webhook?**: Select **Just the `push` event**.
   - **Active**: Check `[x] Active`.
4. Click **Add webhook**.

---

## 4. Verification
1. Make a small code change or push a commit to `main`.
2. Check the GitHub Webhooks page: a green checkmark `✓` indicates successful delivery (HTTP 200).
3. Switch to your Jenkins dashboard: A new build will be scheduled immediately under `votex-ci-cd`.
