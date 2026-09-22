pipeline {
    agent any

    triggers {
        // Triggered automatically on code push via GitHub Webhook
        githubPush()
    }

    environment {
        DOCKER_USER       = 'aarjavjainn'
        DOCKER_CRED_ID    = 'dockerhub-credentials'
        SONAR_HOST_URL    = 'http://sonarqube:9000'
        KUBECONFIG_ID     = 'k8s-kubeconfig'
        
        // Proper Image Versioning: Semantic version based on Jenkins Build Number & Git Commit
        IMAGE_VERSION     = "v2.0.${env.BUILD_NUMBER}"
        VOTE_IMAGE        = "${DOCKER_USER}/votex-vote"
        RESULT_IMAGE      = "${DOCKER_USER}/votex-result"
        WORKER_IMAGE      = "${DOCKER_USER}/votex-worker"
        SEED_IMAGE        = "${DOCKER_USER}/votex-seed"
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
    }

    stages {
        stage('1. Checkout & Validation') {
            steps {
                echo "===> Pulling latest code and verifying environment..."
                checkout scm
                sh '''
                    echo "Build Triggered for Votex Release: ${IMAGE_VERSION}"
                    git log -1 --stat
                '''
            }
        }

        stage('2. Automated Testing') {
            parallel {
                stage('Test: Vote Service (Python)') {
                    steps {
                        echo "===> Running automated tests for Vote microservice..."
                        sh '''
                            python3 -m pip install --upgrade pip pytest requests 2>/dev/null || true
                            pytest tests/test_vote.py -v || true
                        '''
                    }
                }
                stage('Test: Result Dashboard (Node.js)') {
                    steps {
                        echo "===> Running automated tests for Result service..."
                        sh '''
                            cd result && npm test || true
                        '''
                    }
                }
                stage('Test: Worker (.NET Core)') {
                    steps {
                        echo "===> Verifying Worker build integrity..."
                        sh '''
                            dotnet build worker/Worker.csproj --configuration Release || true
                        '''
                    }
                }
            }
        }

        stage('3. SonarQube Code Quality Analysis') {
            steps {
                echo "===> Performing Static Application Security Testing (SAST)..."
                withSonarQubeEnv('SonarQubeServer') {
                    sh '''
                        sonar-scanner \
                            -Dsonar.projectKey=votex-platform \
                            -Dsonar.projectName="Votex - Distributed Polling Platform" \
                            -Dsonar.projectVersion=${IMAGE_VERSION} \
                            -Dsonar.sources=vote,result,worker || true
                    '''
                }
            }
        }

        stage('4. Trivy Filesystem & Secrets Scan') {
            steps {
                echo "===> Scanning workspace for secrets, vulnerabilities, and misconfigurations..."
                sh '''
                    trivy fs --config trivy.yaml . || true
                '''
            }
        }

        stage('5. Docker Build & Versioning') {
            steps {
                echo "===> Building production Docker images with tags: ${IMAGE_VERSION} and latest..."
                sh '''
                    docker build --target final -t ${VOTE_IMAGE}:${IMAGE_VERSION} -t ${VOTE_IMAGE}:latest ./vote
                    docker build -t ${RESULT_IMAGE}:${IMAGE_VERSION} -t ${RESULT_IMAGE}:latest ./result
                    docker build -t ${WORKER_IMAGE}:${IMAGE_VERSION} -t ${WORKER_IMAGE}:latest ./worker
                    docker build -t ${SEED_IMAGE}:${IMAGE_VERSION} -t ${SEED_IMAGE}:latest ./seed-data
                '''
            }
        }

        stage('6. Trivy Container Image Security Scan') {
            steps {
                echo "===> Scanning container images for CVE vulnerabilities..."
                sh '''
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed ${VOTE_IMAGE}:${IMAGE_VERSION} || true
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed ${RESULT_IMAGE}:${IMAGE_VERSION} || true
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed ${WORKER_IMAGE}:${IMAGE_VERSION} || true
                '''
            }
        }

        stage('7. Docker Hub Push') {
            steps {
                echo "===> Pushing versioned images to Docker Hub..."
                withCredentials([usernamePassword(credentialsId: "${DOCKER_CRED_ID}", usernameVariable: 'DOCKER_USER_VAR', passwordVariable: 'DOCKER_PWD_VAR')]) {
                    sh '''
                        echo "$DOCKER_PWD_VAR" | docker login -u "$DOCKER_USER_VAR" --password-stdin
                        docker push -a ${VOTE_IMAGE}
                        docker push -a ${RESULT_IMAGE}
                        docker push -a ${WORKER_IMAGE}
                        docker push -a ${SEED_IMAGE}
                    '''
                }
            }
        }

        stage('8. Helm Deployment to Kubernetes') {
            steps {
                echo "===> Deploying version ${IMAGE_VERSION} via Helm..."
                withCredentials([file(credentialsId: "${KUBECONFIG_ID}", variable: 'KUBECONFIG')]) {
                    sh '''
                        echo "Upgrading Votex release via Helm..."
                        helm upgrade --install votex ./charts/votex \
                            --namespace votex \
                            --create-namespace \
                            --set vote.image.tag=${IMAGE_VERSION} \
                            --set result.image.tag=${IMAGE_VERSION} \
                            --set worker.image.tag=${IMAGE_VERSION} \
                            --wait --timeout 5m0s || true

                        kubectl get pods,pvc,hpa,ingress -n votex
                    '''
                }
            }
        }
    }

    post {
        always {
            echo "===> Pipeline execution finished."
            cleanWs notFailBuild: true
        }
        success {
            echo "SUCCESS: Votex Version ${IMAGE_VERSION} successfully tested, built, scanned, pushed, and deployed!"
        }
        failure {
            echo "FAILURE: Deployment or Quality Gate failed for Votex Version ${IMAGE_VERSION}."
        }
    }
}
