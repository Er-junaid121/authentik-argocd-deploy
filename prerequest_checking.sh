#!/bin/bash

# Prerequisites Setup Script for Authentik + ArgoCD on AWS EKS

echo "🔧 Setting up prerequisites for the project..."

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check and install AWS CLI
if ! command_exists aws; then
    echo "❌ AWS CLI not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
        sudo installer -pkg AWSCLIV2.pkg -target /
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        sudo ./aws/install
    else
        echo "Please install AWS CLI manually from: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
    fi
else
    echo "✅ AWS CLI found"
fi

# Check and install Terraform
if ! command_exists terraform; then
    echo "❌ Terraform not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS with Homebrew
        if command_exists brew; then
            brew tap hashicorp/tap
            brew install hashicorp/tap/terraform
        else
            echo "Please install Homebrew first, then run: brew install terraform"
            exit 1
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt update && sudo apt install terraform
    fi
else
    echo "✅ Terraform found"
fi

# Check and install kubectl
if ! command_exists kubectl; then
    echo "❌ kubectl not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
        chmod +x ./kubectl
        sudo mv ./kubectl /usr/local/bin/kubectl
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x ./kubectl
        sudo mv ./kubectl /usr/local/bin/kubectl
    fi
else
    echo "✅ kubectl found"
fi

# Check and install Git
if ! command_exists git; then
    echo "❌ Git not found. Please install Git manually"
    exit 1
else
    echo "✅ Git found"
fi

echo ""
echo "🎉 Prerequisites check completed!"
echo ""
echo "Next steps:"
echo "1. Configure AWS credentials: aws configure"
echo "2. Create a new repository on GitHub"
echo "3. Follow the step-by-step setup guide"