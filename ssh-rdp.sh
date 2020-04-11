#!/bin/bash

#ToDo:
#	Remote window title is wrong
#	Remote audio: delay is still a bit high (less than 100ms)
#	Understand why audio starts with a long delay unless
#	we keep playing a stream in background (as we now do)
#
#	better commandline parameters handling (use named options)

#Requirements:
    #Local+Remote: ffmpeg,?????????????????,openssh,netevent-git
    #Local: inotify-tools, wmctrl, optional: mpv + taskset from util-linux to get even lower latency but with more cpu use.
    #Remote: xdpyinfo,pulseaudio
    #read/write access to input devices on local and remote system (input group) (sudo gpasswd --add username input)

#Restrictions: only one keyboard supported.

#Remote host (you can pass the following via command line in the format:  john@server:22:0.0)
    RHOST="" # Remote ip or hostname
    RPORT="22"             # Remote ssh port to connect to
    RUSER=""             # The user on the remote side running the real X server
    RDISPLAY="0.0"          # The remote display (ex: 0.0)
    EVDFILE="$HOME/.config/ssh-rdp.input.evd.config"  #Holds the name of the forwarded evdev device 
    KBDFILE="$HOME/.config/ssh-rdp.input.kbd.config"  #Holds the name of the forwarded keyboard evdev device
    HKFILE="$HOME/.config/ssh-rdp.input.hk.config"    #where the keypress codes to switch fullscreen and forward reside

    #GRAB_HOTKEY="" # Grab/Ungrab devices 70=scroll_lock (commented because it is read from a file)
    #FULLSCREENSWITCH_HOTKEY="" # Switch fullscreen (commented because it is read from a file)

#Encoding:
    AUDIO_CAPTURE_SOURCE="guess" # "pulseaudio name like alsa_output.pci-0000_00_1b.0.analog-stereo.monitor" or "guess"
    FPS=60         # frames per second of the stream
    RES="auto"     # "ex: RES="1280x1024" or RES="auto". 
                   # If wrong, video grab will not work.
    OFFSET="+0,0"      # ex: OFFSET="" or OFFSET="+10,+40".
                   # If wrong, video grab will not work.

    AUDIO_BITRATE=128 #kbps
    AUDIO_ENC="-acodec libopus -vbr off -application lowdelay"
    AUDIO_DELAY_COMPENSATION="4000" #The higher the value, the lower the audio delay.
                                    #Setting this too high will likely produce crackling sound.
                                    #Try in range 0-6000
    VIDEO_BITRATE_MAX="5000"  #kbps (or AUTO)
    VIDEO_BITRATE_MAX_SCALE="80" # When VIDEO_BITRATE_MAX is set to "AUTO", only use this percentual of it.

    #cpu encoder
    #VIDEO_ENC="-threads 1 -vcodec libx264 -thread_type slice -slices 1 -level 32 -preset ultrafast -tune zerolatency -intra-refresh 1 -x264opts vbv-bufsize=1:slice-max-size=1500:keyint=$FPS:sliced_threads=1"
    #nvidia gpu encoder
    VIDEO_ENC="-threads 1 -c:v h264_nvenc -preset llhq -delay 0 -zerolatency 1"
    #amd gpu encoder
    #VIDEO_ENC="-threads 1 -vaapi_device /dev/dri/renderD128 -vf 'hwupload,scale_vaapi=format=nv12' -c:v h264_vaapi"
    #intel gpu encoder
    #VIDEO_ENC="???"

    #Remote window title
    WTITLE="$RUSER@$RHOST""$RDISPLAY"

# Decoding
    #ffplay, low latency, no hardware decoding
    #VIDEOPLAYER="ffplay - -nostats -window_title "$WTITLE" -probesize 32 -flags low_delay -framedrop  -fflags nobuffer+fastseek+flush_packets -analyzeduration 0 -sync ext"

    #mpv, less latency, possibly hardware decoding, hammers the cpu.
    VIDEOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-vo-keyboard=no --input-default-bindings=no --hwdec=auto --title="$WTITLE" --untimed --no-cache --profile=low-latency --opengl-glfinish=yes --opengl-swapinterval=0"
    	#older mpv versions, vaapi
    	#VIDEOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-vo-keyboard=no --input-default-bindings=no --hwdec=vaapi --vo=opengl --title="$WTITLE" --untimed --no-cache --audio-buffer=0  --vd-lavc-threads=1 --cache-pause=no --demuxer-lavf-o=fflags=+nobuffer --demuxer-lavf-analyzeduration=0.1 --video-sync=audio --interpolation=no  --opengl-glfinish=yes --opengl-swapinterval=0"

    AUDIOPLAYER="ffplay - -nostats -loglevel warning -flags low_delay -nodisp -probesize 32 -fflags nobuffer+fastseek+flush_packets -analyzeduration 0 -sync ext -af aresample=async=1:min_comp=0.1:first_pts=$AUDIO_DELAY_COMPENSATION"
    #AUDIOPLAYER="taskset -c 0 mpv - --input-cursor=no --input-default-bindings=no --untimed --no-cache --profile=low-latency --speed=1.01"

# Misc
    SSH_CIPHER="" #Optionally, force an ssh cipher to be used
    #SSH_CIPHER="aes256-gcm@openssh.com"


# ### User config ends here ### #

ICFILE_RUNTIME=~/.config/ssh-rdp.input.out.config

generate_ICFILE_from_names() {
    #Also, exits from the script if no keyboard is found
    I_IFS="$IFS"
	IFS=$'\n' ;
    ICFILE_REJ=~/.config/ssh-rdp.input.rej.txt

    rm $ICFILE_RUNTIME $ICFILE_REJ &>/dev/null
    ERROR="0"
    echo [..] Checking input devices...
	for device_name in $(<$EVDFILE) ; do
		evdev_devices=$(events_from_name "$device_name")
		if [ "$evdev_devices" = "" ] ; then
			echo "[!!] Device unavailable : $device_name"
				else
			echo "[OK] Device ready       : $device_name"
			for evdevice in $evdev_devices ; do
				echo "     add event device for $device_name: $evdevice"
				echo -n $evdevice" " >> "$ICFILE_RUNTIME"
			done
		fi
    done
    IFS="$I_IFS"
    echo [..] Reading hotkey file $HKFILE
    read GRAB_HOTKEY FULLSCREENSWITCH_HOTKEY <<< $(<$HKFILE)
    echo [OK] GRAB_HOTKEY=$GRAB_HOTKEY
    echo [OK] FULLSCREENSWITCH_HOTKEY=$FULLSCREENSWITCH_HOTKEY

}

name_from_event(){
	#es: name_from_event event3 
	#Logitech G203 Prodigy Gaming Mouse
	grep 'Name=\|Handlers' /proc/bus/input/devices|grep -B1 "$1"|head -n 1|cut -d \" -f 2
}


events_from_name(){
	#es: vents_from_name Logitech G203 Prodigy Gaming Mouse
	#event13
	#event2
	grep 'Name=\|Handlers' /proc/bus/input/devices|grep -A1 "$1"|cut -d "=" -f 2 |grep -o '[^ ]*event[^ ]*'
}

create_input_files() {
    tmpfile=/tmp/$$devices$$.txt
    sleep 0.1
    timeout=10 #seconds to probe for input devices
    cd /dev/input/

    #Ask user to generate input to auto select input devices to forward
    echo Please, generate input on devices you want to forward, keyboard is mandatory!
    rm $tmpfile &>/dev/null
    for d in event* ; do 
        sh -c "timeout 10 grep . $d -m 1 -c -H |cut -d ":" -f 1 |tee -a $tmpfile &" 
    done 
    echo Waiting 10 seconds for user input...
    sleep $timeout
    list=""
	#Make a list of device names
	rm $EVDFILE &>/dev/null
    for evdevice in $(<$tmpfile) ; do 
		name=$(name_from_event $evdevice|tr " " ".")
		list="$list $name $evdevice off "
		echo $(name_from_event $evdevice)  >> $EVDFILE
    done
    #ask user to select the keyboard device
    echo
	echo "Press a key on the keyboard which will be forwarded."
    KBDDEV=$(inotifywait event* -q | cut -d " " -f 1)
    echo "Got $(name_from_event $KBDDEV)"
    name_from_event $KBDDEV > $KBDFILE

	# create_hk_file
	# uses netevent to generate a file containing the key codes
	# to switch fullscreen and forward devices
		cd /dev/input
		rm $HKFILE &>/dev/null
		sleep 1
		echo ; echo Press the key to forward/unforward input devices
		GRAB_HOTKEY=$(netevent show $KBDDEV 3 -g | grep KEY |cut -d ":" -f 2) ; echo got:$GRAB_HOTKEY
		sleep 0.5
		echo ; echo Press the key to switch fullscreen state
		FULLSCREENSWITCH_HOTKEY=$(netevent show $KBDDEV 3 -g | grep KEY |cut -d ":" -f 2) ; echo got:$FULLSCREENSWITCH_HOTKEY
		echo $GRAB_HOTKEY $FULLSCREENSWITCH_HOTKEY > $HKFILE

		read GRAB_HOTKEY FULLSCREENSWITCH_HOTKEY <<< $(<$HKFILE)
		echo
		echo GRAB_HOTKEY=$GRAB_HOTKEY
		echo FULLSCREENSWITCH_HOTKEY=$FULLSCREENSWITCH_HOTKEY
		
	rm $tmpfile
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
    kill $(list_descendants $$) &>/dev/null
    #ffplay and/or ffmpeg may hangs on remote, kill them by name
    $SSH_EXEC "killall $FFPLAYEXE" &>/dev/null
    $SSH_EXEC "killall $FFMPEGEXE" &>/dev/null
    sleep 1
	$SSH_EXEC "killall -9 $FFPLAYEXE" &>/dev/null
    $SSH_EXEC "killall -9 $FFMPEGEXE" &>/dev/null
    $SSH_EXEC "unlink $FFMPEGEXE" &>/dev/null
    $SSH_EXEC "unlink $FFPLAYEXE" &>/dev/null
    rm $NESCRIPT &>/dev/null
}
trap finish INT TERM EXIT

#Test and report net download speed
benchmark_net() {
    $SSH_EXEC sh -c '"timeout 1 dd if=/dev/zero bs=1b "' | cat - > /tmp/zero
    KBPS=$(( $(wc -c < /tmp/zero) *8/1000   ))
    echo $KBPS
}

FS="F"
setup_input_loop() {    
    #Parse remote hotkeys and perform local actions (eg: Fullscreen switching)
    echo "[..] Setting up input loop and forwarding devices"
    #Prepare netevent script
    i=1
    touch $NESCRIPT
    KBDNAME=$(<$KBDFILE)
    for DEVICE in $(<$ICFILE_RUNTIME) ; do
        echo "     forward input from device $DEVICE..."
        DEVNAME=$(name_from_event "$DEVICE")
        if  [ "$DEVNAME" = "$KBDNAME" ] ; then 
            echo "device add mykbd$i /dev/input/$DEVICE"  >>$NESCRIPT
			echo "hotkey add mykbd$i key:$GRAB_HOTKEY:1 grab toggle" >>$NESCRIPT
			echo "hotkey add mykbd$i key:$GRAB_HOTKEY:0 nop" >>$NESCRIPT
			echo "hotkey add mykbd$i key:$FULLSCREENSWITCH_HOTKEY:1 exec \"/usr/bin/echo FULLSCREENSWITCH_HOTKEY\"" >>$NESCRIPT
			echo "hotkey add mykbd$i key:$FULLSCREENSWITCH_HOTKEY:0 nop" >>$NESCRIPT
                else
            echo "device add dev$i /dev/input/$DEVICE"  >>$NESCRIPT
        fi
        let i=i+1
    done
    echo "output add myremote exec:$SSH_EXEC netevent create" >>$NESCRIPT
    echo "use myremote" >>$NESCRIPT

    echo "[..] Starting netevent daemon"
    netevent daemon -s $NESCRIPT netevent-command.sock | while read -r hotkey; do
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
	ERROR=0
	DEPS_L="bash grep head cut timeout sleep tee inotifywait netevent wc wmctrl awk basename ssh ffplay ["
	DEPS_OPT_L="mpv"
	DEPS_R="bash timeout dd ffmpeg pacmd grep awk tail xdpyinfo"

	#Local deps
	for d in $DEPS_L ; do
		if ! which $d &>/dev/null ; then
			echo "[EE] Cannot find required local executable:" $d
			ERROR=1
		fi
	done
	for d in $DEPS_OPT_L ; do
		if ! which $d &>/dev/null ; then
			echo "[!!] Cannot find required optional executable:" $d
		fi
	done

	#Remote deps
	for d in $DEPS_R ; do
		if ! $SSH_EXEC "which $d &>/dev/null" ; then
			echo "[EE] Cannot find required remote executable:" $d
			ERROR=1
		fi
	done
	
	if [ "$ERROR" = "1" ] ; then
		echo "[EE] Missing packages, cannot continue."
		exit
	fi
		
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
		shift ; shift
		;;
		-h|--host)
		RHOST="$2"
		shift ; shift
		;;
		-p|--port)
		RPORT="$2"
		shift ; shift
		;;
		-d|--display)
		RDISPLAY="$2"
		shift ; shift
		;;
		-r|--resolution)
		RES="$2"
		shift ; shift
		;;
		-o|--offset)
		OFFSET="$2"
		shift ; shift
		;;
		-f|--fps)
		FPS="$2"
		shift ; shift
		;;
		-v|--vbitrate)
		VIDEO_BITRATE_MAX="$2"
		shift ; shift
		;;
		-a|--abitrate)
		AUDIO_BITRATE="$2"
		shift ; shift
		;;
	esac
done



#Sanity check
    me=$(basename "$0")
    if [ -z $RUSER ] || [ -z $RHOST ] || [ "$1" = "-h" ] ; then
        echo Please edit "$me" to suid your needs and/or use the following options:
        echo Usage: "$me" "[OPTIONS]"
        echo ""
        echo "OPTIONS"
        echo ""
        echo "-h|--host          remote host to connect to"
        echo "-u --user          ssh username"
		echo "-p|--port          ssh port"
		echo "-d|--display       remote display (eg: 0.0)"
		echo "-r|--resolution    grab size (eg: 1920x1080) or AUTO"
		echo "-o|--offset        grab offset (eg: +1920,0)"
		echo "-f|--fps           grabbed frames per second"
		echo "-v|--vbitrate      video bitrate in kbps"
		echo "-a|--abitrate      audio bitrate in kbps"
        		
        echo "Example 1: john connecting to jserver, all defaults accepted"
        echo "    Ex: "$me" --user john --host jserver"
        echo 
        echo "Example 2:"
        echo "    john connecting to jserver on ssh port 322, streaming the display 0.0"
        echo "    remote setup is dual head and john selects the right monitor."
        echo "    Stream will be 128kbps for audio and 10000kbps for video:"
        echo "    Ex: $me -u john -s jserver -p 322 -d 0.0 -r 1920x1080 -o +1920,0 -f 60 -a 128 -v 10000"
        echo ""
        echo "    Use: $me inputconfig (to create or change the input config file)"
        echo
        echo "user and host are mandatory."
        echo "default ssh-port: $RPORT"
        echo "default DISPLAY : $RDISPLAY"
        echo "default size    : $RES"
        echo "default offset  : $OFFSET"
        echo "default fps     : $FPS"
        echo "default abitrate: $AUDIO_BITRATE kbps"
        echo "default vbitrate: $VIDEO_BITRATE_MAX kbps"
        exit
    fi
    RDISPLAY=":$RDISPLAY"

    if [ ! -f "$EVDFILE" ] ; then
        echo "[EE] Input configuration file "$EVDFILE" not found!"
        echo "Please, Select which devices to share."
        sleep 2
        create_input_files
    fi

#Setup SSH Multiplexing
	SSH_CONTROL_PATH=$HOME/.config/ssh-rdp$$
    ssh -fN -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH -o ControlPersist=300 $RUSER@$RHOST -p $RPORT

#Shortcut to start remote commands:
    [ ! "$SSH_CIPHER" = "" ] && SSH_CIPHER=" -c $SSH_CIPHER"
    SSH_EXEC="ssh $SSH_CIPHER -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH $RUSER@$RHOST -p $RPORT"

echo "[..] Checking required executables"
deps_or_exit
echo "[OK] Checking required executables"
echo 

generate_ICFILE_from_names

#netevent script file
    NESCRIPT=/tmp/nescript$$

#We need to kill some processes on exit, do it by name.
    FFMPEGEXE=/tmp/ffmpeg$$
    $SSH_EXEC "ln -s \$(which ffmpeg) $FFMPEGEXE"
    FFPLAYEXE=/tmp/ffplay$$
    $SSH_EXEC "ln -s \$(which ffplay) $FFPLAYEXE"

#Measure network download speed?
if [ "$VIDEO_BITRATE_MAX" = "AUTO" ] ; then
	echo
    echo "[..] Measuring network throughput..."
    VIDEO_BITRATE_MAX=$(benchmark_net)
    echo "[OK] VIDEO_BITRATE_MAX = "$VIDEO_BITRATE_MAX"Kbps"
  	VIDEO_BITRATE_MAX=$(( "$VIDEO_BITRATE_MAX" * "$VIDEO_BITRATE_MAX_SCALE" / 100 ))
  	echo "[OK] Scaled Throughput ("$VIDEO_BITRATE_MAX_SCALE"%) = "$VIDEO_BITRATE_MAX"Kbps"
     if [ $VIDEO_BITRATE_MAX -gt 294987 ] ; then
        echo [!!] $VIDEO_BITRATE_MAX"Kbps" is too high!
        VIDEO_BITRATE_MAX=100000 
    fi
    echo "[!!] Using $VIDEO_BITRATE_MAX"Kbps
    echo  
fi

setup_input_loop &
PID1=$!

echo
echo "[..] Trying to connect to $RUSER@$RHOST:$RPORT"
echo "     and stream display $DISPLAY"
echo "     with size $RES and offset: $OFFSET"
echo

#Play a test tone to open the pulseaudio sinc prior to recording it to (avoid audio delays at start!?)	#This hangs at exit, so we'll kill it by name.
    $SSH_EXEC "$FFPLAYEXE -nostats -nodisp -f lavfi -i \"sine=220:4\" -af volume=0.001 -autoexit" &
    #PID5=$!


#Guess audio capture device?
    if [ "$AUDIO_CAPTURE_SOURCE" = "guess" ] ; then
		echo "[..] Guessing audio capture device"
        AUDIO_CAPTURE_SOURCE=$($SSH_EXEC echo '$(pacmd list | grep "<.*monitor>" |awk -F "[<>]" "{print \$2}" | tail -n 1)')
        # or: AUDIO_CAPTURE_SOURCE=$($SSH_EXEC echo '$(pactl list sources short|grep monitor|awk "{print \$2}" | head -n 1)
        echo "[OK] Guessed audio capture source:" $AUDIO_CAPTURE_SOURCE
		echo
    fi

#Auto video grab size?
    if [ "$RES" = "auto" ] || [ "$RES" = "" ] ; then
		echo "[..] Guessing remote resolution"
        RES=$($SSH_EXEC "export DISPLAY=$RDISPLAY ; xdpyinfo | awk '/dimensions:/ { print \$2; exit }'")
        echo "[OK] Auto grab resolution: $RES"
        echo
    fi


#Grab Audio
	echo [..] Start audio streaming...
    $SSH_EXEC sh -c "\
        export DISPLAY=$RDISPLAY ;\
        $FFMPEGEXE -v quiet -nostdin -loglevel warning -y -f pulse -ac 2 -i "$AUDIO_CAPTURE_SOURCE"  -b:a "$AUDIO_BITRATE"k "$AUDIO_ENC" -f nut -\
    " | $AUDIOPLAYER &
    PID4=$!

	echo [..] Start video streaming...
    $SSH_EXEC sh -c "\
        export DISPLAY=$RDISPLAY ;\
        $FFMPEGEXE -nostdin -loglevel warning -y -f x11grab -r $FPS -framerate $FPS -video_size $RES -i "$RDISPLAY""$OFFSET"  -b:v "$VIDEO_BITRATE_MAX"k  -maxrate "$VIDEO_BITRATE_MAX"k \
        "$VIDEO_ENC" -f_strict experimental -syncpoints none -f nut -\
    " | $VIDEOPLAYER


