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
        stage('1. Checkout') {
            steps {
                echo "Pulling source code..."
                checkout scm
                sh '''
                    echo "Build triggered for version: ${IMAGE_VERSION}"
                    git log -1 --stat
                '''
            }
        }

        stage('2. Run Tests') {
            parallel {
                stage('Test: Vote API') {
                    steps {
                        echo "Testing Vote service..."
                        sh '''
                            python3 -m pip install --upgrade pip pytest requests 2>/dev/null || true
                            pytest tests/test_vote.py -v || true
                        '''
                    }
                }
                stage('Test: Result App') {
                    steps {
                        echo "Testing Result service..."
                        sh '''
                            cd result && npm test || true
                        '''
                    }
                }
                stage('Test: Worker Build') {
                    steps {
                        echo "Building Worker..."
                        sh '''
                            dotnet build worker/Worker.csproj --configuration Release || true
                        '''
                    }
                }
            }
        }

        stage('3. SonarQube Scan') {
            steps {
                echo "Running SonarQube scan..."
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

        stage('4. Trivy FS Scan') {
            steps {
                echo "Scanning filesystem vulnerabilities..."
                sh '''
                    trivy fs --config trivy.yaml . || true
                '''
            }
        }

        stage('5. Docker Build') {
            steps {
                echo "Building container images..."
                sh '''
                    docker build --target final -t ${VOTE_IMAGE}:${IMAGE_VERSION} -t ${VOTE_IMAGE}:latest ./vote
                    docker build -t ${RESULT_IMAGE}:${IMAGE_VERSION} -t ${RESULT_IMAGE}:latest ./result
                    docker build -t ${WORKER_IMAGE}:${IMAGE_VERSION} -t ${WORKER_IMAGE}:latest ./worker
                    docker build -t ${SEED_IMAGE}:${IMAGE_VERSION} -t ${SEED_IMAGE}:latest ./seed-data
                '''
            }
        }

        stage('6. Trivy Image Scan') {
            steps {
                echo "Scanning container images..."
                sh '''
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed ${VOTE_IMAGE}:${IMAGE_VERSION} || true
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed ${RESULT_IMAGE}:${IMAGE_VERSION} || true
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed ${WORKER_IMAGE}:${IMAGE_VERSION} || true
                '''
            }
        }

        stage('7. Docker Push') {
            steps {
                echo "Pushing images to Docker Hub..."
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

        stage('8. Deploy to Kubernetes') {
            steps {
                echo "Deploying ${IMAGE_VERSION} via Helm..."
                withCredentials([file(credentialsId: "${KUBECONFIG_ID}", variable: 'KUBECONFIG')]) {
                    sh '''
                        helm upgrade --install votex ./k8s/helm/votex \
                            --namespace votex \
                            --create-namespace \
                            -f ./k8s/helm/votex/values-eks.yaml \
                            --set vote.image.tag=${IMAGE_VERSION} \
                            --set result.image.tag=${IMAGE_VERSION} \
                            --set worker.image.tag=${IMAGE_VERSION} \
                            --wait --timeout 5m0s

                        echo "Checking rollout status..."
                        kubectl rollout status deployment/vote -n votex --timeout=120s
                        kubectl rollout status deployment/result -n votex --timeout=120s
                        kubectl rollout status deployment/worker -n votex --timeout=120s

                        kubectl get pods,pvc,hpa,svc -n votex -o wide
                    '''
                }
            }
        }
    }

    post {
        always {
            cleanWs notFailBuild: true
        }
        success {
            echo "Build and deployment finished successfully for version ${IMAGE_VERSION}"
        }
        failure {
            echo "Build failed. Rolling back helm release..."
            withCredentials([file(credentialsId: "${KUBECONFIG_ID}", variable: 'KUBECONFIG')]) {
                sh 'helm rollback votex -n votex 2>/dev/null || true'
            }
        }
    }
}
