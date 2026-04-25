# train.py
# Trains a simple neural network on MNIST, applies pruning, and saves a sparse model

import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms

# ========================
# Device
# ========================
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

# ========================
# Hyperparameters
# ========================
INPUT_SIZE = 784
HIDDEN_SIZE = 128
NUM_CLASSES = 10
EPOCHS = 20
FINETUNE_EPOCHS = 5
LR = 1e-3
BATCH_SIZE = 64
PRUNE_THRESHOLD = 0.05  # adjust if needed

# ========================
# Dataset
# ========================
transform = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize((0.5,), (0.5,))
])

train_dataset = datasets.MNIST(root="./data", train=True, transform=transform, download=True)
test_dataset = datasets.MNIST(root="./data", train=False, transform=transform)

train_loader = torch.utils.data.DataLoader(dataset=train_dataset, batch_size=BATCH_SIZE, shuffle=True)
test_loader = torch.utils.data.DataLoader(dataset=test_dataset, batch_size=BATCH_SIZE, shuffle=False)

# ========================
# Model
# ========================
class SimpleNN(nn.Module):
    def __init__(self):
        super(SimpleNN, self).__init__()
        self.fc1 = nn.Linear(INPUT_SIZE, HIDDEN_SIZE)
        self.relu = nn.ReLU()
        self.fc2 = nn.Linear(HIDDEN_SIZE, NUM_CLASSES)

    def forward(self, x):
        x = x.view(-1, INPUT_SIZE)
        x = self.fc1(x)
        x = self.relu(x)
        x = self.fc2(x)
        return x

model = SimpleNN().to(device)

# ========================
# Loss & Optimizer
# ========================
criterion = nn.CrossEntropyLoss()
optimizer = optim.Adam(model.parameters(), lr=LR)

# ========================
# Training Function
# ========================
def train(model, loader, optimizer):
    model.train()
    for images, labels in loader:
        images, labels = images.to(device), labels.to(device)

        outputs = model(images)
        loss = criterion(outputs, labels)

        optimizer.zero_grad()
        loss.backward()
        optimizer.step()

# ========================
# Evaluation Function
# ========================
def evaluate(model, loader):
    model.eval()
    correct = 0
    total = 0

    with torch.no_grad():
        for images, labels in loader:
            images, labels = images.to(device), labels.to(device)
            outputs = model(images)

            _, predicted = torch.max(outputs.data, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()

    return 100 * correct / total

# ========================
# Step 1: Train
# ========================
print("Training model...")
for epoch in range(EPOCHS):
    train(model, train_loader, optimizer)
    acc = evaluate(model, test_loader)
    print(f"Epoch [{epoch+1}/{EPOCHS}] Accuracy: {acc:.2f}%")

# ========================
# Step 2: Prune
# ========================
print("\nApplying pruning...")
with torch.no_grad():
    for name, param in model.named_parameters():
        if 'weight' in name:
            mask = torch.abs(param) > PRUNE_THRESHOLD
            param *= mask

# ========================
# Step 3: Sparsity Check
# ========================
total = 0
zeros = 0

for param in model.parameters():
    total += param.numel()
    zeros += (param == 0).sum().item()

sparsity = 100 * zeros / total
print(f"Sparsity after pruning: {sparsity:.2f}%")

# ========================
# Step 4: Fine-tune
# ========================
print("\nFine-tuning after pruning...")
for epoch in range(FINETUNE_EPOCHS):
    train(model, train_loader, optimizer)
    acc = evaluate(model, test_loader)
    print(f"Fine-tune Epoch [{epoch+1}/{FINETUNE_EPOCHS}] Accuracy: {acc:.2f}%")

# ========================
# Final Evaluation
# ========================
final_acc = evaluate(model, test_loader)
print(f"\nFinal Accuracy: {final_acc:.2f}%")

# ========================
# Save Model
# ========================
torch.save(model.state_dict(), "pruned_model.pth")
print("\nModel saved as pruned_model.pth")
