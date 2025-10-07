# personal-server

# New Hetzner Online Bare Metal machine steps:
- activate rescue system
```bash
# update
apt update -y;
apt full-upgrade -y;
# podman
apt install podman -y;

# Remove prior partition table
wipefs /dev/sda -a;
wipefs /dev/sdb -a;

# Install bootc with btrfs
podman run --rm --privileged --pid=host --network=host \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev \
  -v ~/.ssh/authorized_keys:/authorized_keys:ro \
  --security-opt label=type:unconfined_t \
  quay.io/fedora/fedora-bootc:latest \
  bootc install to-disk --wipe --filesystem=btrfs \
  --root-ssh-authorized-keys /authorized_keys /dev/sda;

# Create unified RAID0 btrfs storage
mkdir -p /mnt/root;
mount /dev/sda3 /mnt/root;
btrfs device add --force /dev/sdb /mnt/root;
btrfs balance start --force -dconvert=raid0 -mconvert=raid0 /mnt/root;
umount /mnt/root;
reboot;

```# milvus-bare-metal
