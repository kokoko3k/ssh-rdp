#!/usr/bin/env bash

#ToDo:
#    Remote window title is wrong
#    Remote audio: delay is still a bit high (less than 100ms)
#    Understand why audio starts with a long delay unless
#    we keep playing a stream in background (as we now do)
#   * allow tho choose video player by command line

#Requirements:
    #Local+Remote: ffmpeg,openssh,netevent-git
    #Local: wmctrl, optional: mpv + taskset from util-linux to get even lower latency but with more cpu use.
    #Remote: xdpyinfo,pulseaudio
    #read/write access to input devices on local and remote system (input group) (sudo gpasswd --add username input)

#Remote host
    RHOST="" # Remote ip or hostname
    RPORT="22"             # Remote ssh port to connect to
    RUSER=""               # The user on the remote side running the real X server
    RDISPLAY="0.0"         # The remote display (ex: 0.0)
    EVDFILE="$HOME/.config/ssh-rdp.input.evd.config"  #Holds the name of the forwarded evdev device
    KBDFILE="$HOME/.config/ssh-rdp.input.kbd.config"  #Holds the name of the forwarded keyboard evdev device
    HKFILE="$HOME/.config/ssh-rdp.input.hk.config"    #where the keypress codes to switch fullscreen and forward reside

#Encoding:
    AUDIO_CAPTURE_SOURCE="AUTO" # "pulseaudio name like alsa_output.pci-0000_00_1b.0.analog-stereo.monitor" or "guess"
    FPS=60         # frames per second of the stream
    RES="AUTO"     # "ex: RES="1280x1024" or RES="AUTO".
                   # If wrong, video grab will not work.
    OFFSET="+0,0"  # ex: OFFSET="" or OFFSET="+10,+40".
                   # If wrong, video grab will not work.

    #The "null,null" video filters will be changed to -vf scale by sed later on if prescale is requested
    #VIDEO_ENC_CPU="-threads 1 -vcodec libx264 -thread_type slice -slices 1 -level 32 -preset ultrafast -tune zerolatency -intra-refresh 1 -x264opts vbv-bufsize=1:slice-max-size=1500:keyint=$FPS:sliced_threads=1 -pix_fmt nv12 -vf 'null,null'"
    VIDEO_ENC_CPU="-threads 1 -vcodec libx264 -thread_type slice -slices 1 -level 32 -preset ultrafast -tune zerolatency -intra-refresh 1 -x264opts keyint=$FPS:sliced_threads=1 -pix_fmt nv12 -vf 'null,null'"
    VIDEO_ENC_CPU_RGB="-threads 1 -vcodec libx264rgb -profile:v high444 -thread_type slice -slices 1 -level 32 -preset ultrafast -tune zerolatency -intra-refresh 1 -x264opts keyint=$FPS:sliced_threads=1 -pix_fmt bgr24 -vf 'null,null'"
    VIDEO_ENC_NVGPU="-threads 1 -c:v h264_nvenc -preset llhq -delay 0 -zerolatency 1 -vf 'null,null'"
    VIDEO_ENC_NVGPU_HEVC="-threads 1 -c:v hevc_nvenc -preset llhq -delay 0 -zerolatency 1 -vf 'null,null'"
    VIDEO_ENC_AMDGPU="-threads 1 -vaapi_device /dev/dri/renderD128 -c:v h264_vaapi -bf 0 -vf 'null,null,hwupload,scale_vaapi=format=nv12'"
    VIDEO_ENC_AMDGPU_HEVC="-threads 1 -vaapi_device /dev/dri/renderD128 -c:v hevc_vaapi -bf 0 -vf 'null,null,hwupload,scale_vaapi=format=nv12'"
    VIDEO_ENC_INTELGPU="-threads 1 -vaapi_device /dev/dri/renderD128 -c:v h264_vaapi -bf 0 -vf 'null,null,hwupload,scale_vaapi=format=nv12'"
    #VIDEO_ENC_INTELGPU="-threads 1 -vaapi_device /dev/dri/renderD128 -c:v h264_vaapi -bf 0 -vf 'null,null,format=nv12,hwupload'"

    AUDIO_ENC_OPUS="-acodec libopus -vbr off -application lowdelay -frame_duration 10"    #opus, low delay great quality
    AUDIO_ENC_PCM="-acodec pcm_s16le "    #pcm, low delay, best quality

    VIDEOENC="cpu"
    AUDIOENC="opus"

    VIDEO_BITRATE_MAX="5000"  #kbps (or AUTO)
    VIDEO_BITRATE_MAX_SCALE="80" # When VIDEO_BITRATE_MAX is set to "AUTO", only use this percentual of it.
    AUDIO_BITRATE=128 #kbps

    AUDIO_DELAY_COMPENSATION="4000" #The higher the value, the lower the audio delay.
                                    #Setting this too high will likely produce crackling sound.
                                    #Try in range 0-8000

    #Prescale desktop before sending?
    PRESCALE="" # eg: "" or something like "1280x720"

    #Prescaling quality see https://ffmpeg.org/ffmpeg-scaler.html for possible values
    SCALE_FLT="fast_bilinear" #bilinear,bicubic,lanczos,spline...

    #Remote window title
    #WTITLE="$RUSER@$RHOST""$RDISPLAY"
    WTITLE="ssh-rdp""-"\["$$"\]

# Misc
    SSH_CIPHER="" #Optionally, force an ssh cipher to be used
    #SSH_CIPHER="aes256-gcm@openssh.com"


# ### User config ends here ### #

ICFILE_RUNTIME=~/.config/ssh-rdp.input.out.config

print_error()   { echo -e "\e[1m\e[91m[EE] $1\e[0m" ;};
print_warning() { echo -e "\e[1m\e[93m[WW] $1\e[0m" ;};
print_notice()  { echo -e "\e[1m[!!] $1\e[0m" ;};
print_ok()      { echo -e "\e[1m\e[92m[OK] $1\e[0m" ;};
print_pending() { echo -e "\e[1m\e[94m[..] $1\e[0m" ;};

ask_continue_or_exit(){
    while true; do
        read -p "$(print_warning "Do you want to continue anyway (not recommended) (y/n) ? ")" yn
        case $yn in
            [Yy]* ) ERROR=0; break;;
            [Nn]* ) ERROR=1; break;;
            * ) print_error "Please answer y or n.";;
        esac
    done
    if [ "$ERROR" = "1" ] ; then
        print_error "Cannot continue."
        exit
            else
        print_warning "Proceeding anyway..."
    fi
}

generate_ICFILE_from_names() {
    #Also, exits from the script if no keyboard is found
    I_IFS="$IFS"
    IFS=$'\n' ;
    ICFILE_REJ=~/.config/ssh-rdp.input.rej.txt

    rm $ICFILE_RUNTIME $ICFILE_REJ &>/dev/null
    ERROR="0"
    print_pending "Checking input devices..."
    for device_name in $(<$EVDFILE) ; do
        evdev_devices=$(events_from_name "$device_name")
        if [ "$evdev_devices" = "" ] ; then
            print_warning "Device unavailable : $device_name"
                else
            print_ok "Device ready       : $device_name"
            for evdevice in $evdev_devices ; do
                echo "     add event device for $device_name: $evdevice"
                echo -n $evdevice" " >> "$ICFILE_RUNTIME"
            done
        fi
    done
    IFS="$I_IFS"
    print_pending "Reading hotkey file $HKFILE"
    read GRAB_HOTKEY FULLSCREENSWITCH_HOTKEY <<< $(<$HKFILE)
    print_ok "GRAB_HOTKEY=$GRAB_HOTKEY"
    print_ok "FULLSCREENSWITCH_HOTKEY=$FULLSCREENSWITCH_HOTKEY"
}

function get_input_event_device(){
    #Show the first event device that "emits some input"
    cd /dev/input/
    tmpfile=/tmp/$$devices$$.txt
    rm $tmpfile &>/dev/null
    touch $tmpfile
    timeout=120

    #Listen for events
    pids=("")
    sleep 0.1
    for d in event* ; do
        timeout $timeout sh -c "grep . $d -m 1 -c -H |cut -d ":" -f 1 > $tmpfile" &
        pids+=("$!")
    done

    #Wait for one event to come
    while ! [ -s $tmpfile ] ; do
        sleep 0.1
    done

    #Show the event device
    cat $tmpfile 

    #Cleanup
    for pid in ${pids[@]} ; do
        kill $pid &>/dev/null
    done
    rm $tmpfile
}

name_from_event(){
    #es: name_from_event event3
    #Logitech G203 Prodigy Gaming Mouse
    grep 'Name=\|Handlers' /proc/bus/input/devices|grep -w -B1 "$1"|head -n 1|cut -d \" -f 2
}

events_from_name(){
    #es: vents_from_name Logitech G203 Prodigy Gaming Mouse
    #event13
    #event2
    grep 'Name=\|Handlers' /proc/bus/input/devices|grep -A1 "$1"|cut -d "=" -f 2 |grep -o '[^ ]*event[^ ]*'
}

check_local_input_group(){
    if ! id -nG $(id -u)|grep -qw input  ; then
        echo
        print_warning "local user is not in the input group,"
        print_warning "but /dev/input/* access is required to forward input devices."
        ask_continue_or_exit
    fi
}

check_remote_uinput_access(){
	UINPUT=/dev/uinput # /dev/uinput
	$SSH_EXEC "test -e $UINPUT" || E="noexist"
	if [ "$E" = "noexist" ] ; then
        echo
        print_warning "Remote system has no $UINPUT"
        print_warning "which is needed to forward input devices."
        print_warning "Please, configure it to load the uinput module or build uinput into the kernel."
        ask_continue_or_exit
			else #/dev/uinput was found
		$SSH_EXEC "test -w $UINPUT" || E="noaccess"
		$SSH_EXEC "test -r $UINPUT" || E="noaccess"
		if [ "$E" = "noaccess" ] ; then
			echo
			print_warning "Remote user is missing R/W access to $UINPUT"
			print_warning "which is needed to forward input devices."
			ask_continue_or_exit
		fi
	fi
}

create_input_files() {
    check_local_input_group
    tmpfile=/tmp/$$devices$$.txt
    sleep 0.1
    rm $EVDFILE &>/dev/null

    #Ask user to generate input to auto select input devices to forward
    echo
    print_pending "Please, press a key on the keyboard you want to forward."
    KBDDEV=$(get_input_event_device)
    KBDNAME=$(name_from_event $KBDDEV)
    echo -ne "\r"
    print_ok "Got keyboard: $KBDNAME on $KBDDEV.\n"
    name_from_event $KBDDEV > $KBDFILE
    echo $KBDNAME > $EVDFILE

    ANOTHER_DEVICE=1
    while [ $ANOTHER_DEVICE == 1 ]; do
        while true; do
            read -t 0.5 -N 255  #empty input buffer
            read -p "$(print_warning "Do you want to forward other devices? (y/n) ? ")" yn
            case $yn in
                [Yy]* )
                        print_pending "Please, generate input with the device you want to forward."
                        EVDEV=$(get_input_event_device)
                        EVDEV_NAME=$(name_from_event $EVDEV)
                        if grep "$EVDEV_NAME" $EVDFILE >/dev/null ; then
                            print_error "Not adding $EVDEV_NAME because it is already in the forward list."
                                else
                            print_ok "Got $EVDEV_NAME on $EVDEV"
                            echo -ne "\r"
                            echo $EVDEV_NAME >> $EVDFILE
                        fi
                        echo
                        ;;
                [Nn]* )
                        ANOTHER_DEVICE=0; break;;
                * )
                        print_error "Please answer y or n.";;
            esac
        done
    done


    # create_hk_file
    # uses netevent to generate a file containing the key codes
    # to switch fullscreen and forward devices
        cd /dev/input
        rm $HKFILE &>/dev/null
        sleep 0.1
        echo ; print_pending "Press the key to that will be used to forward/unforward input devices"
        GRAB_HOTKEY=$(netevent show $KBDDEV 3 -g | grep KEY |cut -d ":" -f 2) ; print_ok "got:$GRAB_HOTKEY"
        sleep 0.5
        echo ; print_pending "Now press the key that will be used to switch fullscreen state"
        FULLSCREENSWITCH_HOTKEY=$(netevent show $KBDDEV 3 -g | grep KEY |cut -d ":" -f 2) ; print_ok "got:$FULLSCREENSWITCH_HOTKEY"
        echo $GRAB_HOTKEY $FULLSCREENSWITCH_HOTKEY > $HKFILE

        read GRAB_HOTKEY FULLSCREENSWITCH_HOTKEY <<< $(<$HKFILE)
        echo
        echo GRAB_HOTKEY=$GRAB_HOTKEY
        echo FULLSCREENSWITCH_HOTKEY=$FULLSCREENSWITCH_HOTKEY

}

list_descendants() {
    local children=$(ps -o pid= --ppid "$1")
    for pid in $children ; do
        list_descendants "$pid"
    done
    echo "$children"
}

#Clean function
finish() {
    #echo ; echo TRAP: finish.

    if ! [ "$REXEC_EXIT" = "" ] ; then
        print_pending "Executing $REXEC_EXIT"
        $SSH_EXEC "bash -s" < "$REXEC_EXIT"
        print_ok "$REXEC_EXIT exited."
    fi

    #ffplay and/or ffmpeg may hangs on remote, kill them by name
#    $SSH_EXEC "killall $FFPLAYEXE" &>/dev/null
#    $SSH_EXEC "killall $FFMPEGEXE" &>/dev/null
    $SSH_EXEC "kill \$(pidof FFPLAYEXE)" &>/dev/null
    $SSH_EXEC "kill \$(pidof $FFMPEGEXE)" &>/dev/null
    sleep 1
#   $SSH_EXEC "killall -9 $FFPLAYEXE" &>/dev/null
#   $SSH_EXEC "killall -9 $FFMPEGEXE" &>/dev/null
    $SSH_EXEC "kill -9 \$(pidof $FFPLAYEXE)" &>/dev/null
    $SSH_EXEC "kill -9 \$(pidof $FFMPEGEXE)" &>/dev/null
    $SSH_EXEC "unlink $FFMPEGEXE" &>/dev/null
    $SSH_EXEC "unlink $FFPLAYEXE" &>/dev/null
    #kill multiplexing ssh
    ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" $RHOST 2>/dev/null
    kill $(list_descendants $$) &>/dev/null

    rm $NESCRIPT &>/dev/null
    rm $NE_CMD_SOCK&>/dev/null

}

#Test and report net download speed
benchmark_net() {
    $SSH_EXEC sh -c '"timeout 1 dd if=/dev/zero bs=1b "' | cat - > /tmp/$$_zero_$$
    KBPS=$(( $(wc -c < /tmp/$$_zero_$$) *8/1000   ))
    echo $KBPS
    rm /tmp/$$_zero_$$
}

FS="F"
setup_input_loop() {
    #Parse remote hotkeys and perform local actions (eg: Fullscreen switching)
    print_pending "Setting up input loop and forwarding devices"
    #Prepare netevent script
    i=1
    touch $NESCRIPT
    KBDNAME=$(<$KBDFILE)

    # From 2.2.1, netevent splitted grab in grab-devices and write-events
    # it also introduced the -V switch; check if it reports anything with -V
    # to react to the change.
    netevent_version=$(netevent 2>/dev/null -V)
    if ! [ "_$netevent_version" == "_" ] ; then netevent_is="NEW" ; fi

    for DEVICE in $(<$ICFILE_RUNTIME) ; do
        echo "     forward input from device $DEVICE..."
        DEVNAME=$(name_from_event "$DEVICE")
        if  [ "$DEVNAME" = "$KBDNAME" ] ; then # Device is keyboard -> add it and setup hotkeys
            echo "device add mykbd$i /dev/input/$DEVICE"  >>$NESCRIPT
            if [ $netevent_is == "NEW" ] ; then 
                echo "hotkey add mykbd$i key:$GRAB_HOTKEY:0 'write-events toggle ; grab-devices toggle'" >>$NESCRIPT
                  else
                echo "hotkey add mykbd$i key:$GRAB_HOTKEY:0 grab toggle" >>$NESCRIPT
            fi
            echo "action set grab-changed exec '/usr/bin/echo Is input forwarded 1=Yes,0=No ? \$NETEVENT_GRABBING' " >>$NESCRIPT
            echo "hotkey add mykbd$i key:$GRAB_HOTKEY:1 nop" >>$NESCRIPT
            echo "hotkey add mykbd$i key:$FULLSCREENSWITCH_HOTKEY:0 exec \"/usr/bin/echo FULLSCREENSWITCH_HOTKEY\"" >>$NESCRIPT
            echo "hotkey add mykbd$i key:$FULLSCREENSWITCH_HOTKEY:1 nop" >>$NESCRIPT
                else # Device is not keyboard -> just add it
            echo "device add dev$i /dev/input/$DEVICE"  >>$NESCRIPT
        fi
        let i=i+1
    done
    echo "output add myremote exec:$SSH_EXEC netevent create" >>$NESCRIPT
    echo "use myremote" >>$NESCRIPT

    echo
    print_pending "Starting netevent daemon with script $NESCRIPT"
    netevent daemon -s $NESCRIPT $NE_CMD_SOCK | while read -r hotkey; do
        echo "read hotkey: " $hotkey
        if [ "$hotkey" = "FULLSCREENSWITCH_HOTKEY" ] ; then
            if [ "$FS" = "F" ] ; then
                wmctrl -b add,fullscreen -r "$WTITLE"
                wmctrl -b add,above -r "$WTITLE"
                FS="T"
                    else
                wmctrl -b remove,fullscreen -r "$WTITLE"
                wmctrl -b remove,above -r "$WTITLE"
                FS="F"
            fi
        fi
    done
}


deps_or_exit(){
    #Check that dependancies are ok, or exits the script
    check_local_input_group
    check_remote_uinput_access
    DEPS_L="bash grep head cut timeout sleep tee netevent wc wmctrl awk basename ssh ffplay mpv ["
    DEPS_OPT_L=""
    DEPS_R="bash timeout dd ffmpeg pactl grep awk tail xdpyinfo netevent"

    #Local deps
    for d in $DEPS_L ; do
        ERROR=0
        if ! which $d &>/dev/null ; then
            print_error "Cannot find required local executable: $d"
            ask_continue_or_exit
        fi
    done
    for d in $DEPS_OPT_L ; do
        if ! which $d &>/dev/null ; then
            print_warning "Cannot find required optional executable: $d"
        fi
    done

    #Remote deps
    for d in $DEPS_R ; do
        ERROR=0
        if ! $SSH_EXEC "which $d &>/dev/null" ; then
            print_error "Cannot find required remote executable: $d"
            ask_continue_or_exit
        fi
    done
}


# ### MAIN ### ### MAIN ### ### MAIN ### ### MAIN ###

if [ "$1 " = "inputconfig " ] ; then
    create_input_files
    exit
fi

#Parse arguments
while [[ $# -gt 0 ]]
do
    arg="$1"
    case $arg in
        -u|--user)
            RUSER="$2"
            shift ; shift ;;
        -s|--server)
            RHOST="$2"
            shift ; shift ;;
        -p|--port)
            RPORT="$2"
            shift ; shift ;;
        --sshopt)
            SSHOPT="$2"
            shift ; shift ;;
        -d|--display)
            RDISPLAY="$2"
            shift ; shift ;;
        -r|--resolution)
            RES="$2"
            shift ; shift ;;
        --prescale)
            PRESCALE="$2"
            shift ; shift ;;
        -o|--offset)
            OFFSET="$2"
            shift ; shift ;;
        --follow)
            FOLLOW_STRING='-follow_mouse 1'
            shift ;;
        -f|--fps)
            FPS="$2"
            shift ; shift ;;
        --pasource)
            AUDIO_CAPTURE_SOURCE="$2"
            shift ; shift ;;
        --videoenc)
            VIDEOENC="$2"
            shift ; shift ;;
        --audioenc)
            AUDIOENC="$2"
            shift ; shift ;;
        --customv)
            VIDEO_ENC_CUSTOM="$2"
            shift ; shift ;;
        --customa)
            AUDIO_ENC_CUSTOM="$2"
            shift ; shift ;;
        --audioenc)
            AUDIOENC="$2"
            shift ; shift ;;
        #--videoplayer)
        #    VIDEOPLAYER="$2"
        #    shift ; shift ;;
        --vplayeropts)
            VPLAYEROPTS="$2"
            shift ; shift ;;
        -v|--vbitrate)
            VIDEO_BITRATE_MAX="$2"
            shift ; shift ;;
        -a|--abitrate)
            AUDIO_BITRATE="$2"
            shift ; shift ;;
        --rexec-before)
            REXEC_BEFORE="$2"
            shift ; shift ;;
        --rexec-exit)
            REXEC_EXIT="$2"
            shift ; shift ;;
        --rexec-late)
            REXEC_LATE="$2"
            shift ; shift ;;
        *)
            shift ;;
    esac
done

# Decoding
    #ffplay, low latency, no hardware decoding
        #VIDEOPLAYER="ffplay -  -vf "setpts=0.5*PTS" -nostats -window_title "$WTITLE" -probesize 32 -flags low_delay -framedrop  -fflags nobuffer+fastseek+flush_packets -analyzeduration 0 -sync ext"

    #mpv, less latency, possibly hardware decoding, may hammer the cpu.
        #Untimed:
            #VIDEOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-vo-keyboard=no --input-default-bindings=no --hwdec=auto --title="$WTITLE" --untimed --no-cache --profile=low-latency --opengl-glfinish=yes --opengl-swapinterval=0"

        #speed=2 instead of untimed, seems smoother:
            VIDEOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-vo-keyboard=no --input-default-bindings=no --hwdec=auto --title="$WTITLE" --speed=2 --no-cache --profile=low-latency --opengl-glfinish=yes --opengl-swapinterval=0 $VPLAYEROPTS"

        #less hammering, experimental, introduce some stuttering :/
            #VIDEOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-vo-keyboard=no --input-default-bindings=no --hwdec=auto --title="$WTITLE" --speed=2 --no-cache --profile=low-latency --opengl-glfinish=yes --opengl-swapinterval=0 --cache-pause=yes --cache-pause-wait=0.001"

        #older mpv versions, vaapi
            #VIDEOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-vo-keyboard=no --input-default-bindings=no --hwdec=vaapi --vo=gpu --gpu-api=opengl --title="$WTITLE" --untimed --no-cache --audio-buffer=0  --vd-lavc-threads=1 --cache-pause=no --demuxer-lavf-o=fflags=+nobuffer --demuxer-lavf-analyzeduration=0.1 --video-sync=audio --interpolation=no  --opengl-glfinish=yes --opengl-swapinterval=0"

    AUDIOPLAYER="ffplay - -nostats -loglevel warning -flags low_delay -nodisp -probesize 32 -fflags nobuffer+fastseek+flush_packets -analyzeduration 0 -sync ext -af aresample=async=1:min_comp=0.1:first_pts=$AUDIO_DELAY_COMPENSATION"

    if [ "$AUDIOENC" = "show" ] || [ "$VIDEOENC" = "show" ] ; then
        if [ "$AUDIOENC" = "show" ] ; then
            print_pending "Audio encoding presets: \
            \n opus: \"$AUDIO_ENC_OPUS\"      \
            \n pcm:  \"$AUDIO_ENC_PCM\"       \
            \n"
        fi

        if [ "$VIDEOENC" = "show" ] ; then
            print_pending "Video encoding presets:       \
            \n cpu:           \"$VIDEO_ENC_CPU\"         \
            \n cpurgb:        \"$VIDEO_ENC_CPU_RGB\"     \
            \n amdgpu:        \"$VIDEO_ENC_AMDGPU\"      \
            \n amdgpu_hevc:   \"$VIDEO_ENC_AMDGPU_HEVC\" \
            \n intelgpu:      \"$VIDEO_ENC_INTELGPU\"    \
            \n nvgpu:         \"$VIDEO_ENC_NVGPU\"       \
            \n nvgpu_hevc:    \"$VIDEO_ENC_NVGPU_HEVC\"  \
            \n"
        fi
        exit
    fi

    me=$(basename "$0")
    if [ -z $RUSER ] || [ -z $RHOST ] || [ "$1" = "-h" ] ; then
        echo Please edit "$me" to suit your needs and/or use the following options:
        echo Usage: "$me" "[OPTIONS]"
        echo ""
        echo "OPTIONS"
        echo ""
        echo "Use $me inputconfig to create or change the input config file"
        echo ""
        echo "-s, --server        Remote host to connect to"
        echo "-u, --user          ssh username"
        echo "-p, --port          ssh port"
        echo "    --sshopt        pass additional ssh option (omit -o)"
        echo "-d, --display       Remote display (eg: 0.0)"
        echo "-r, --resolution    Grab size (eg: 1920x1080) or AUTO"
        echo "-o, --offset        Grab offset (eg: +1920,0)"
        echo "    --follow        pan the grabbed area when the cursor reaches the border"
        echo "    --prescale      Scale video before encoding (eg: 1280x720)."
        echo "                    Has impact on remote cpu use and can increase latency too."
        echo "-f, --fps           Grabbed frames per second"
        echo "    --pasource      Capture from the specified pulseaudio source. (experimental and may introduce delay)"
        echo "                    Use AUTO to guess, use ALL to capture everything."
        echo "                    Eg: alsa_output.pci-0000_00_1b.0.analog-stereo.monitor"
        echo ""
        echo "    --videoenc      Video encoder can be: cpu,cpurgb,amdgpu,amdgpu_hevc,intelgpu,nvgpu,nvgpu_hevc,zerocopy,custom or show"
        echo "                    \"zerocopy\" is experimental and causes ffmpeg to use kmsgrab"
        echo "                    to grab the framebuffer and pass frames to vaapi encoder."
        echo "                    You've to run 'setcap cap_sys_admin+ep $(which ffmpeg)' on the server to use zerocopy."
        echo "                    --display, --follow are ignored when using zerocopy."
        echo "                    specify \"show\" to print the options for each preset."
        echo ""
        echo "    --customv       Specify a string for video encoder stuff when videoenc is set to custom"
        echo "                    Eg: \"-threads 1 -c:v h264_nvenc -preset llhq -delay 0 -zerolatency 1\""
        echo "    --audioenc      Audio encoder can be: opus,pcm,null,custom or show"
        echo "                    \"null\" disables audio grabbing completely"
        echo "                    specify \"show\" to print the options for each other preset."
        echo ""
        echo "    --customa       Specify a string for audio encoder stuff when videoenc is set to custom"
        echo "                    Eg: \"-acodec libopus -vbr off -application lowdelay\""
        echo "-v, --vbitrate      Video bitrate in kbps or AUTO"
        echo "                    AUTO will use 80% of the maximum available throughput."
        echo "-a, --abitrate      Audio bitrate in kbps"
        echo "    --vplayeropts   Additional options to pass to videoplayer"
        echo "                    Eg: \"--video-output-levels=limited --video-rotate=90\""
        echo "    --rexec-before  Execute the specified script via 'sh' just before the connection"
        echo "    --rexec-exit    Execute the specified script via 'sh' before exiting the script"
        echo "    --rexec-late    Execute the specified script via 'sh' after input(s) forward, before video grab"
        #echo "    --videoplayer
        echo
        echo "Example 1: john connecting to jserver, all defaults accepted"
        echo "    "$me" --user john --server jserver"
        echo
        echo "Example 2:"
        echo "    john connecting to jserver on ssh port 322, streaming the display 0.0"
        echo "    remote setup is dual head and john selects the right monitor."
        echo "    Stream will be 128kbps for audio and 10000kbps for video:"
        echo "    Ex: $me -u john -s jserver -p 322 -d 0.0 -r 1920x1080 -o +1920,0 -f 60 -a 128 -v 10000"
        echo
        echo "Example 3:"
        echo "    Bill connecting to jserver on ssh port 322, streaming the display 0.0"
        echo "    Stream will be 128kbps for audio and 10000kbps for video:"
        echo "    Bill wants untouched audio, 144fps and encode via intelgpu, he needs to correct video output levels"
        echo "    Ex: $me -u bill -s bserver -p 322 -d 0.0 -f 144 -v 80000 --audioenc pcm --videoenc intelgpu --vplayeropts \"--video-output-levels=limited\""
        echo
        echo "user and host are mandatory."
        echo "default ssh-port: $RPORT"
        echo "default DISPLAY : $RDISPLAY"
        echo "default size    : $RES"
        echo "default offset  : $OFFSET"
        echo "default fps     : $FPS"
        echo "default video encoder: $VIDEOENC"
        echo "default audio encoder: $AUDIOENC"
        echo "default abitrate: $AUDIO_BITRATE kbps"
        echo "default vbitrate: $VIDEO_BITRATE_MAX kbps"
        exit
    fi

#Sanity checks

    RDISPLAY=":$RDISPLAY"

    if [ "$AUDIOENC" = "custom" ] && [ "$AUDIO_ENC_CUSTOM" = "" ] ; then
        print_error "Custom audioencoder requested, but no custom encoder string provided. use --customa <something>"
        exit
    fi

    if [ "$VIDEOENC" = "custom" ] && [ "$VIDEO_ENC_CUSTOM" = "" ] ; then
        print_notice "Custom video encoder requested, but no custom encoder string provided. use --customv <something>"
        exit
    fi

    if [ ! -f "$EVDFILE" ] ; then
        print_error "Input configuration file "$EVDFILE" not found!"
        echo "Please, Select which devices to share."
        sleep 2
        create_input_files
    fi

trap finish EXIT
trap exit INT TERM

#Setup SSH Multiplexing
    SSH_CONTROL_PATH=$HOME/.config/ssh-rdp$$
    print_pending "Starting ssh multiplexed connection"
    if ssh -fN -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH -o ControlPersist=60 -o "$SSHOPT" $RUSER@$RHOST -p $RPORT; then
        print_ok "Started ssh multiplexed connection"
            else
        print_warning "Cannot start ssh multiplexed connection"
        ask_continue_or_exit
    fi
#Shortcut to start remote commands:
    [ ! "$SSH_CIPHER" = "" ] && SSH_CIPHER=" -c $SSH_CIPHER"
    SSH_EXEC="ssh $SSH_CIPHER -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH $RUSER@$RHOST -p $RPORT"

print_pending "Checking required executables..."
deps_or_exit
print_ok "Checked required executables"
echo

generate_ICFILE_from_names

#netevent script file and command sock
    NESCRIPT=/tmp/nescript$$
    NE_CMD_SOCK=/tmp/neteventcommandsock$$

#We need to kill some processes on exit, do it by name.
    FFMPEGEXE=/tmp/ffmpeg$$
    $SSH_EXEC "ln -s \$(which ffmpeg) $FFMPEGEXE"
    FFPLAYEXE=/tmp/ffplay$$
    $SSH_EXEC "ln -s \$(which ffplay) $FFPLAYEXE"

#Measure network download speed?
if [ "$VIDEO_BITRATE_MAX" = "AUTO" ] ; then
    echo
    print_pending "Measuring network throughput..."
    VIDEO_BITRATE_MAX=$(benchmark_net)
    echo "[OK] VIDEO_BITRATE_MAX = "$VIDEO_BITRATE_MAX"Kbps"
      VIDEO_BITRATE_MAX=$(( "$VIDEO_BITRATE_MAX" * "$VIDEO_BITRATE_MAX_SCALE" / 100 ))
      print_ok "Scaled Throughput ("$VIDEO_BITRATE_MAX_SCALE"%) = "$VIDEO_BITRATE_MAX"Kbps"
     if [ $VIDEO_BITRATE_MAX -gt 294987 ] ; then
        print_pending "$VIDEO_BITRATE_MAX Kbps" is too high!
        VIDEO_BITRATE_MAX=100000 
    fi
    print_warning "Using $VIDEO_BITRATE_MAX Kbps"
    echo
fi

echo

if ! [ "$REXEC_BEFORE" = "" ] ; then
    print_pending "Executing $REXEC_BEFORE"
    $SSH_EXEC "bash -s" < "$REXEC_BEFORE"
    print_ok "$REXEC_BEFORE exited."
fi

setup_input_loop &
sleep 0.1 #(just to not shuffle output messages)
PID1=$!

echo
print_pending "Trying to connect to $RUSER@$RHOST:$RPORT"
echo "     and stream display $DISPLAY"
echo "     with size $RES and offset: $OFFSET"
echo

#Play a test tone to open the pulseaudio sinc prior to recording it to (avoid audio delays at start!?)    #This hangs at exit, so we'll kill it by name.
    $SSH_EXEC "$FFPLAYEXE -loglevel warning -nostats -nodisp -f lavfi -i \"sine=220:4\" -af volume=0.001 -autoexit" &
    PID5=$!


#Guess audio capture device?
    if [ "$AUDIO_CAPTURE_SOURCE" = "AUTO" ] ; then
        print_pending "Guessing audio capture device"
        AUDIO_CAPTURE_SOURCE=$($SSH_EXEC echo '$(pactl list sources short|grep monitor|awk "{print \$2}" | head -n 1)')
        # or: AUDIO_CAPTURE_SOURCE=$($SSH_EXEC echo '$(pacmd list-sources | grep "<.*monitor>" |awk -F "[<>]" "{print \$2}" | tail -n 1)')
        print_warning "Guessed audio capture source: $AUDIO_CAPTURE_SOURCE"
        echo
    fi
#
    if [ "$AUDIO_CAPTURE_SOURCE" = "ALL" ] ; then
        print_pending "Guessing ALL audio capture devices"
        AUDIO_CAPTURE_SOURCE=$($SSH_EXEC echo '$(pactl list sources short|awk "{print \$2}")')
        # or: AUDIO_CAPTURE_SOURCE=$($SSH_EXEC echo '$(pacmd list-sources | grep "name\: <.*>" |awk -F "[<>]" "{print \$2}")')
        print_warning "Guessed following audio capture sources: $AUDIO_CAPTURE_SOURCE"
        echo
    fi

#Auto video grab size?
    if [ "$RES" = "AUTO" ] || [ "$RES" = "" ] ; then
        print_pending "Guessing remote resolution"
        RES=$($SSH_EXEC "export DISPLAY=$RDISPLAY ; xdpyinfo | awk '/dimensions:/ { print \$2; exit }'")
#         print_warning "Auto grab resolution: $RES"
        echo
    fi



#Select video encoder:
    case  $VIDEOENC  in
        cpu)
            VIDEO_ENC="$VIDEO_ENC_CPU" ;;
        cpurgb)
            VIDEO_ENC="$VIDEO_ENC_CPU_RGB" ;;
        nvgpu)
            VIDEO_ENC="$VIDEO_ENC_NVGPU" ;;
        nvgpu_hevc)
            VIDEO_ENC="$VIDEO_ENC_NVGPU_HEVC" ;;
        amdgpu)
            VIDEO_ENC="$VIDEO_ENC_AMDGPU" ;;
        amdgpu_hevc)
            VIDEO_ENC="$VIDEO_ENC_AMDGPU_HEVC" ;;
        custom)
            VIDEO_ENC="$VIDEO_ENC_CUSTOM" ;;
        intelgpu)
            VIDEO_ENC="$VIDEO_ENC_INTELGPU" ;;
        zerocopy)
            VIDEO_ENC="" ;;
        *)
            print_error "Unsupported video encoder"
            exit ;;
    esac 

#Select audio encoder:
    case  $AUDIOENC  in
        opus)
            AUDIO_ENC="$AUDIO_ENC_OPUS";;
        pcm)
            AUDIO_ENC="$AUDIO_ENC_PCM" ;;
        custom)
            AUDIO_ENC="$AUDIO_ENC_CUSTOM" ;;
        null)
            AUDIO_ENC="null" ;;
        *)
            print_error "Unsupported audio encoder"
            exit ;;
    esac 

#Insert the scale filter by replacing the dummy filters null,null.
    if [ ! "$PRESCALE" = "" ] ; then
        VIDEO_ENC=$(sed "s/null,null/scale=$PRESCALE/" <<< "$VIDEO_ENC")
    fi

#Grab Audio
    if ! [ "$AUDIO_ENC" = "null" ] ; then
        print_pending "Start audio streaming..."

        for ASOURCE in $AUDIO_CAPTURE_SOURCE ; do
            AUDIO_SOURCE_GRAB_STRING="$AUDIO_SOURCE_GRAB_STRING  -f pulse -ac 2 -fragment_size 1024 -i $ASOURCE "
        done
        #insert amix
        AUDIO_SOURCE_GRAB_STRING="$AUDIO_SOURCE_GRAB_STRING -filter_complex amix=inputs=$(echo $AUDIO_CAPTURE_SOURCE|wc -w)"

        $SSH_EXEC sh -c "\
            export DISPLAY=$RDISPLAY ;\
            $FFMPEGEXE -v quiet -nostdin -loglevel warning -y "$AUDIO_SOURCE_GRAB_STRING"   -b:a "$AUDIO_BITRATE"k "$AUDIO_ENC" -f nut -\
        " | $AUDIOPLAYER &
        PID4=$!
    fi

    if ! [ "$REXEC_LATE" = "" ] ; then
        print_pending "Executing $REXEC_LATE"
        $SSH_EXEC "bash -s" < "$REXEC_LATE"
        print_ok "$REXEC_LATE exited."
    fi

#Grab Video
    print_pending "Start video streaming..."

    #$SSH_EXEC sh -c "\
    #    export DISPLAY=$RDISPLAY ;\
    #    $FFMPEGEXE -nostdin -loglevel warning -y -f x11grab -framerate $FPS -video_size $RES -i "$RDISPLAY""$OFFSET" -sws_flags $SCALE_FLT -b:v #"$VIDEO_BITRATE_MAX"k  -maxrate "$VIDEO_BITRATE_MAX"k \
    #    "$VIDEO_ENC" -f_strict experimental -syncpoints none -f nut -\
    #" | $VIDEOPLAYER

    if [ ! "$VIDEOENC" = "zerocopy" ] ; then
        $SSH_EXEC sh -c "\
            export DISPLAY=$RDISPLAY ;\
            export VAAPI_DISABLE_INTERLACE=1;\
            $FFMPEGEXE -nostdin -loglevel warning -y -f x11grab "$FOLLOW_STRING" -framerate $FPS -video_size $RES -i "$RDISPLAY""$OFFSET" -sws_flags $SCALE_FLT -b:v "$VIDEO_BITRATE_MAX"k  -maxrate "$VIDEO_BITRATE_MAX"k \
            "$VIDEO_ENC" -f_strict experimental -syncpoints none -f nut -\
        " | $VIDEOPLAYER
    else
        #Zero copy test:
        RES=$(sed "s/\x/\:/" <<< "$RES")
        OFFSET=$(sed "s/\+//" <<< "$OFFSET")
        OFFSET=$(sed "s/\,/:/" <<< "$OFFSET")
        if [ ! "$PRESCALE" = "" ] ; then
            NEWRES=$(sed "s/\x/\:/" <<< "$PRESCALE")
                else
            NEWRES=$RES
        fi

        $SSH_EXEC sh -c ";\
                $FFMPEGEXE -nostdin  -loglevel warning  -y -framerate $FPS -f kmsgrab -i -  -sws_flags $SCALE_FLT -b:v "$VIDEO_BITRATE_MAX"k -maxrate "$VIDEO_BITRATE_MAX"k \
                -vf hwmap=derive_device=vaapi,crop="$RES:$OFFSET",scale_vaapi="$NEWRES":format=nv12 -c:v h264_vaapi -bf 0  -b:v "$VIDEO_BITRATE_MAX"k  -maxrate "$VIDEO_BITRATE_MAX"k -f_strict experimental -syncpoints none  -f nut -\
                " | $VIDEOPLAYER
    fi
