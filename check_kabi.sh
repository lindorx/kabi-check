#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2023 Fan Dai <lindorx@163.com>

USE_TEMPLET="./check_kabi.sh -i -r -c uos419_defconfig -p Kabi.path_* -k Module.kabi_*"

ERNUM_NO_ARCH=1
ERNUM_NO_KABI_FILE=2
ERNUM_NO_SYMS_FILE=3
ERNUM_CHECK_WRONG=4

CC=gcc
GENKSYMS=./scripts/genksyms/genksyms
KABI_TMP_DIR=./kabiTempDir
KABI_SYMS=./Kabi.syms
MODULE_TMP_KABI=$KABI_TMP_DIR/Module.kabi_list
cpus=`grep processor /proc/cpuinfo | wc -l`
ARCH=`arch`

if [ "$ARCH" == "x86_64" ]; then
    kernel_arch="x86"
elif [ "$ARCH" == "aarch64" ]; then
    kernel_arch="arm64"
elif [ "$ARCH" == "loongarch64" ]; then
    kernel_arch="loongarch"
else
    echo "暂时不支持 ${ARCH} 架构"
    return $ERNUM_NO_ARCH
fi

if (($cpus == 0)); then
    cpus=2
    echo "warning: 无法获取CPU数量，默认为2"
fi

GCC_VERSION=$($CC --version | head -n 1 | awk '{split($NF,a,"."); print a[1]}')
if (( $GCC_VERSION < 8 )); then
    echo "warning: 检测到gcc的版本为 $GCC_VERSION，如果小于8，校验可能出错"
fi

# 处理参数
arg_nums=$#
init_flag=0
clean_flag=0
help_flag=0
while getopts "ihrc:k:p:" arg
do
    case $arg in
    k)
        #校验kabi列表
        Module_kabi_f=$OPTARG
        ;;
    p)
        #kabi路径文件列表
        Kabi_path_f=$OPTARG
        ;;
    c)
        #指定使用的配置文件
        kernel_config=$OPTARG
        ;;
    i)
        #进行初始化
        init_flag=1
        ;;
    r)
        #清理环境
        clean_flag=1
        ;;
    h)
        #帮助信息
        help_flag=1
    esac
done

HELP_INFO="Example: ${USE_TEMPLET}\n
\t-h\t显示帮助信息
\t-i\t初始化内核环境
\t-r\t清理校验过程遗留的文件
\t-k []\t指定要校验的kabi白名单
\t-p []\t指定kabi白名单对应的路径文件
\t-c []\t指定初始化内核环境使用的配置文件"

# 帮助信息
function help_info()
{
    echo -e "$HELP_INFO"
}

# 预处理代码
function pre_c_s()
{
    ret=$ERNUM_NO_KABI_FILE
    kabi_files_c_i=`grep "\.c" $Kabi_path_f | sed 's/\.c$/\.i/'`
    kabi_files_S_s=`grep "\.S" $Kabi_path_f | sed 's/\.S$/\.s/'`
    kabi_files_S_si=`grep "\.S" $Kabi_path_f | sed 's/\.S$/\.s\.i/'`
    kabi_files_S_sc=`grep "\.S" $Kabi_path_f | sed 's/\.S$/\.s\.c/'`
    kabi_files_i="$kabi_files_c_i $kabi_files_S_si"
    kabi_file_array=(${kabi_files_i})
    kabi_files_num=${#kabi_file_array[@]}

    if [ -n "$kabi_files_c_i" ]; then
        ret=0
        echo "+ 预处理C文件"
        #预处理c代码文件
        make -j${cpus} CPP="gcc -E -D__GENKSYMS__" $kabi_files_c_i >> /dev/null
    fi

    if [ -n "$kabi_files_S_si" ]; then
        ret=0
        echo "+ 预处理汇编文件"
        #预处理汇编代码
        make -j${cpus} CPP="gcc -E -D__ASSEMBLY__ -Wa,-gdwarf-2" $kabi_files_S_s >> /dev/null
        for i in ${kabi_files_S_s[@]}
        do
            (echo "#include <linux/kernel.h>" ; \
            echo "#include <asm/asm-prototypes.h>" ; \
            cat $i | \
            grep "\<___EXPORT_SYMBOL\>" | \
            sed 's/.*___EXPORT_SYMBOL[[:space:]]*\([a-zA-Z0-9_]*\)[[:space:]]*,.*/EXPORT_SYMBOL(\1);/' ) > $i.c
        done
        make -j${cpus} CPP="gcc -E -D__GENKSYMS__" ${kabi_files_S_si} >> /dev/null
    fi

    return $ret
}

# 处理文件
# $1: 起始下标
# $2: 间隔
# $3: 循环次数
function build_cs()
{
    for ((ci=$1,ct=0;ct<$3;ci+=$2,ct++));
    do
        ( $GENKSYMS < ${kabi_file_array[$ci]} ) >> $KABI_TMP_DIR/kabi.$!
    done
}

# 分配器，以间隔方式分配数据，防止汇编文件被放在同一个线程处理占用过长时间
# $1: 总负载数量
# $2: 工作函数
function thread_alloc()
{
    nums=$1
    let avg2=nums/cpus
    let avg1=avg2+1
    let for2=cpus
    let for1=nums-avg2*cpus
    for ((i=0;i<for1;i++));
    do
        eval $2 $i $cpus $avg1 &
    done
    for ((i;i<for2;i++));
    do
        eval $2 $i $cpus $avg2 &
    done
    wait
}

# 获取全部kabi校验码
function get_symvers()
{
    echo "--- 获取内核KABI ---"
    rm -rf $KABI_TMP_DIR
    mkdir -p $KABI_TMP_DIR
    pre_c_s
    ret=$?
    if (( $ret > 0 )); then
        echo "+ 未能获取kabi所在路径，使用\"-p\"重新指定"
        exit $ret
    fi
    #并行处理所有的文件
    thread_alloc $kabi_files_num build_cs
    echo "--- 文件处理完成 ---"
    #将查到的kabi汇总到KABI_SYMS
    KABI_LIST=(`awk '{gsub(/;|^__crc_/,"");printf("%s\t%s\n",$3,$1)}' $KABI_TMP_DIR/* | tee $KABI_SYMS`)
    echo "--- 获取内核KABI完成 ---"
}

# 校验kabi
function kabi_check()
{
    echo "--- 开始校验 ---"
    if [ $(wc -l $KABI_SYMS | awk '{print$1}') -eq 0 ]; then
        echo "+ $KABI_SYMS 文件不可用，预处理过程出错"
        return $ERNUM_NO_SYMS_FILE
    fi
    MODULE_KABI_LIST=(`awk '{printf("%s\t%s\n",$1,$2)}' $Module_kabi_f | tee $MODULE_TMP_KABI`)
    ERROR_KABI=$(grep -vf $KABI_SYMS $MODULE_TMP_KABI && grep -vf $MODULE_TMP_KABI $KABI_SYMS >> /dev/null)
    if (( $? == 0 )); then
        echo "+ 校验失败，错误KABI如下:"
        echo "$ERROR_KABI"
        return $ERNUM_CHECK_WRONG
    fi
    return 0
}

# 初始化内核环境，包括必要的工具和源码
function init_kernel()
{
    KERNEL_CONFIG_PATH="arch/${kernel_arch}/configs/${kernel_config}"
    if [ ! -f $KERNEL_CONFIG_PATH ]; then
        echo "未找到配置文件："${KERNEL_CONFIG_PATH}
        return 2
    fi

    echo "--- 初始化环境 ---"
    make distclean -j ${cpus}
    (cp $KERNEL_CONFIG_PATH .config && \
    make olddefconfig -j ${cpus} && \
    make scripts -j ${cpus} && \
    make prepare -j ${cpus} && \
    make init -j ${cpus} ) >> /dev/null 2>&1
    make drivers/scsi/scsi_sysfs.o
    echo "--- 环境初始化完成 ---"
}

# 清理环境
function clean_all()
{
    if [ -z "$kabi_files_S_sc" ] && [ -n "$Kabi_path_f" ]; then
        kabi_files_S_sc=`grep "\.S" $Kabi_path_f | sed 's/\.S$/\.s\.c/'`
    fi
    rm -rf $KABI_TMP_DIR $KABI_SYMS $kabi_files_S_sc
    make distclean -j >> /dev/null
    echo "--- 完成环境清理 ---"
}

# 默认参数
function default_arg()
{
    init_flag=1
    clean_flag=1
    Module_kabi_f="./uos/kabi/Module.kabi_$ARCH"
    Kabi_path_f="./uos/kabi/Kabi.path_$ARCH"
    kernel_config="uos419_defconfig"
}

function fargs()
{
    if (( $arg_nums == 0 )); then
        default_arg
    fi
    if (( $help_flag > 0 )); then
        help_info
        exit 0
    fi
    if (( $init_flag > 0 )) && [ -n $kernel_config ]; then
        init_kernel
        retnum=$?
    fi
    if [ -n "$Module_kabi_f" ]; then
        if [ -n "$Kabi_path_f" ]; then
            get_symvers
            kabi_check
            retnum=$?
            if (( $retnum == 0 )); then
                echo "--- 校验完成，没有问题 ---"
            else
                echo "--- 校验失败 ---"
            fi
        fi
    fi
    if (( $clean_flag > 0 )); then
        clean_all
    fi
    exit $retnum
}

fargs
