// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define PROC_NAME    "debug_42"
#define PROC_CONTENT "42\n"

static ssize_t debug_42_read(struct file *file, char __user *buf,
			     size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(buf, count, ppos,
				       PROC_CONTENT, strlen(PROC_CONTENT));
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops debug_42_fops = {
	.proc_read = debug_42_read,
};
#else
static const struct file_operations debug_42_fops = {
	.owner = THIS_MODULE,
	.read  = debug_42_read,
};
#endif

static struct proc_dir_entry *debug_42_entry;

static int __init debug_42_init(void)
{
	debug_42_entry = proc_create(PROC_NAME, 0444, NULL, &debug_42_fops);
	if (!debug_42_entry) {
		pr_err("debug_42: failed to create /proc/%s\n", PROC_NAME);
		return -ENOMEM;
	}
	pr_info("debug_42: /proc/%s created\n", PROC_NAME);
	return 0;
}

static void __exit debug_42_exit(void)
{
	proc_remove(debug_42_entry);
}

module_init(debug_42_init);
module_exit(debug_42_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Benjamin Boortz <bennib@mailbox.org>");
MODULE_DESCRIPTION("Debug /proc entry returning 42 — boot verification");
