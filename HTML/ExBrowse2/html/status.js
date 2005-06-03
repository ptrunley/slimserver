/* * * * * * * * *\
 *    Status     *
\* * * * * * * * */

var statusbackend;

var playbutton, stopbutton;
var prevbutton, nextbutton;
var repeatbuttons = new Array();
var shufflebuttons = new Array();
var volumebar, progressbar, progresstext;
var playstringtext, songtext, artisttext, albumtext;

var progressAt, progressEnd, progressEndText;
var curPlayMode;
var lastCoverArt, currentSong, songCount;

function getStatusPeriodically() {
	statusbackend.submit();
	setTimeout(getStatusPeriodically, 5000);
}

function makeRepShufClosure(i, buttonlist, cmdstring) {
	return function() {
		for (var j = 0; j < 3; j++) {
			buttonlist[j].setState(j == i ? true : false);
		}
		statusbackend.submit(cmdstring + i);
	}
}

function timetostr(t) {
	var mins = Math.floor(t / 60);
	var secs = (t % 60);
	if (secs == 0) {
		return mins + ':00';
	} else if (secs < 10) {
		return mins + ':0' + secs;
	} else {
		return mins + ':' + secs;
	}
}

function updateProgressBar() {
	if (curPlayMode == "play" || curPlayMode == "pause") {
		progressbar.setValue(progressAt / progressEnd * 50);
		if (progressEnd == 0) {
			progresstext.setText(' ' + timetostr(progressAt));
		} else {
			progresstext.setText(' ' + timetostr(progressAt) + ' / ' + progressEndText);
		}
	} else {
		progressbar.setValue(-1);
		progresstext.setText(' 0:00 / ' + progressEndText);
	}
}

function updateCounterPeriodically() {
	setTimeout("updateCounterPeriodically()", 1000);

	if (curPlayMode == "play") {
		progressAt++;
		if(progressAt > progressEnd && progressEnd > 0) progressAt = progressAt % progressEnd;
	}
	updateProgressBar();
}

function updatePlayInfo() {
	var playstring;
	if (curPlayMode == "play") {
		playstring = "Now playing";
		playbutton.setState(true);
		stopbutton.setState(false);
	} else if (curPlayMode == "pause") {
		playstring = "Now paused on";
		playbutton.setState(false);
		stopbutton.setState(false);
	} else {
		playstring = "Now stopped on";
		playbutton.setState(false);
		stopbutton.setState(true);
	}
	if (currentSong) {
		playstring += " <b>" + currentSong + "</b> of <b>" + songCount + "</b>";
	}
	playstringtext.setText(playstring);
};

function displaySong(song, artist, album) {
	songtext.setText(song);
	artisttext.setText(artist);
	albumtext.setText(album);
}

function statusMiscHandler(resp) {
	var url = resp.getTag("coverart");
	if (url) {
		if (url != lastCoverArt) {
			document.getElementById("coverart").src = "/music/" + url + "/thumb.jpg";
			lastCoverArt = url;
		}
		document.getElementById("coverart").style.display = "block";
		document.getElementById("playtext").style.left = "120px";
		document.getElementById("playtext").style.width = "270px";
	} else {
		document.getElementById("coverart").style.display = "none";
		document.getElementById("playtext").style.left = "10px";
		document.getElementById("playtext").style.width = "380px";
	}

	displaySong(resp.getTag("songtitle"), resp.getTag("artist"), resp.getTag("album"));

	currentSong = resp.getTag("currentsong");
	songCount = resp.getTag("songcount");

	curPlayMode = resp.getTag("playmode");
	updatePlayInfo();

	progressAt = resp.getTag("songtime");
	var newProgressEnd = resp.getTag("songlength");
	if (progressEnd != newProgressEnd) {
		progressEnd = newProgressEnd;
		progressEndText = timetostr(progressEnd);
	}

	updateProgressBar();
}

function statusFirstLoad() {
	statusRefs++;
	maybeDoneLoading();
	statusbackend.removeHandler(statusFirstLoad);
}

function initStatusControls() {
	statusbackend.addHandler(statusMiscHandler);

	playbutton = JXTK.Button().createSimpleButton(statusbackend, "playbutton", "playmode", "play", function() {
		if (curPlayMode != "play") {
			curPlayMode = "play";
		} else {
			curPlayMode = "pause";
		}
		updatePlayInfo();
		statusbackend.submit("&p0=pause");
	});

	stopbutton = JXTK.Button().createSimpleButton(statusbackend, "stopbutton", "playmode", "stop", function() {
		curPlayMode = "stop";
		updatePlayInfo();
		progressAt = 0;
		updateProgressBar();
		statusbackend.submit("&p0=stop");
	});

	prevbutton = JXTK.Button().createButton("prevbutton");
	prevbutton.addClickHandler(function() {
		currentSong--;
		if (currentSong == 0) currentSong = songCount;
		playlistcombo.selectIndex(currentSong-1);
		displaySong(playlist[currentSong-1].title, playlist[currentSong-1].artist, playlist[currentSong-1].album);
		curPlayMode = "play";
		updatePlayInfo();
		progressAt = 0;
		updateProgressBar();
		statusbackend.submit("&p0=playlist&p1=jump&p2=-1");
	});

	nextbutton = JXTK.Button().createButton("nextbutton");
	nextbutton.addClickHandler(function() {
		currentSong++;
		if (currentSong > songCount) currentSong = 1;
		playlistcombo.selectIndex(currentSong-1);
		displaySong(playlist[currentSong-1].title, playlist[currentSong-1].artist, playlist[currentSong-1].album);
		curPlayMode = "play";
		updatePlayInfo();
		progressAt = 0;
		updateProgressBar();
		statusbackend.submit("&p0=playlist&p1=jump&p2=%2b1");
	});

	for (var i = 0; i < 3; i++) {
		repeatbuttons[i] = JXTK.Button().createSimpleButton(
			statusbackend, "repeat" + i, "repeat", i,
			makeRepShufClosure(i, repeatbuttons, "&p0=playlist&p1=repeat&p2=")
		);
	}

	for (var i = 0; i < 3; i++) {
		shufflebuttons[i] = JXTK.Button().createSimpleButton(
			statusbackend, "shuf" + i, "shuffle", i,
			makeRepShufClosure(i, shufflebuttons, "&p0=playlist&p1=shuffle&p2=")
		);
	}

	playstringtext = JXTK.Textbox().createTextbox("playstring");

	songtext = JXTK.Textbox().createTextbox("song");
	artisttext = JXTK.Textbox().createTextbox("artist");
	albumtext = JXTK.Textbox().createTextbox("album");

	volumebar = JXTK.ButtonBar().createButtonBar("volume");
	volumebar.populate("IMG", 11, "html/images/volpixel_t.gif", 4, 2);
	volumebar.useXMLValue(statusbackend, function(resp) {
		return resp.getTag("volume") / 10;
	});
	volumebar.addClickHandler(function (button) {
		var volindex = button.el.index;
		volumebar.setValue(volindex);
		statusbackend.submit("&p0=mixer&p1=volume&p2=" + volindex * 10);
	});

	progressbar = JXTK.ButtonBar().createButtonBar("progressbar");
	progressbar.populate("IMG", 50, "html/images/pixel.gif");

	progresstext = JXTK.Textbox().createTextbox("progresstext");

	statusbackend.addHandler(statusFirstLoad);
}

function initStatus() {
	statusbackend = JXTK.Backend().createBackend(webroot + 'status.xml');

	initStatusControls();

	updateCounterPeriodically();
}

function updateStatusCombined(str) {
	// Technically this is "the old way" and should be replaced, but it's probably a good
	// thing to have all calls from external HTML filtered through just one function, so I'm
	// leaving it here. I also really don't want to go through and replace all the calls to
	// updateStatusCombined in each of the templates.
	statusbackend.submit(str);
}
