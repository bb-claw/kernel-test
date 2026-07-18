KERNEL_TREE  ?= $(HOME)/git/linux-next
LABEL        ?= next
LINUX_NEXT   := 1
# linux-next has no rc tags — use: make fetch-next
# then: make all NO_FETCH=1
