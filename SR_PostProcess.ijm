@File(label = "Input directory", style = "directory") input
@File(label = "Output directory", style = "directory") output
@String(label = "File suffix", value = ".lif") suffix
@Boolean(label = "Apply Temporal Median Subtraction", value=true) Bool_TempMed
@String(label = "Sub-pixel localization method", choices={"PSF: Integrated Gaussian", "PSF: Gaussian", "PSF: Elliptical Gaussian (3D astigmatism)", "Radial symmetry", "Centroid of local neighborhood", "Phasor Fitting", "No estimator"}) ts_estimator
@String(label = "Fitting method", choices={"Least squares", "Weighted Least squares", "Maximum likelihood"}) ts_method
@String(label = "Peak threshold", choices={"2*std(Wave.F1)", "std(Wave.F1)"}) ts_threshold
@Integer(label = "Fit radius", value=3) ts_fitradius
@Boolean(label = "Apply Drift Correction", value=true) Bool_DriftCorr
@Boolean(label = "Apply Chromatic Abberation Correction", value=true) Bool_ChromCorr
@Integer(label = "Drift correction steps", value=5) ts_drift_steps
@File(label = "Chromatic aberration directory", style = "directory", value="C:\\Temp", description="The directory where the chromatic aberration JSON files are stored") jsondir

@Boolean(label = "Merge reappearing molecules", value=true) Bool_AutoMerge
@String(label = "Filtering String", value = "intensity>500 & sigma>70 & uncertainty<50") filtering_string
@String(label="Visualization Method",choices={"Averaged shifted histograms","Scatter plot","Normalized Gaussian","Histograms","No Renderer"}) ts_renderer

@Boolean(label = "16-bit output instead of 32-bit", value=false) Bool_16bit

@Boolean(label = "Display images while processing?", value=false) Bool_display

@Float(label = "Gain conversion factor of the camera (photoelectrons to ADU)", value=11.71) photons2adu
@Integer(label = "EM gain (set to 0 for no EM; value will be overwritten if found in the metadata)", value = 50) EM_gain
@Float(label = "Pixel size [nm] (value will be overwritten if found in the metadata)", value = 100) pixel_size

if (EM_gain>0) isemgain=true;
else isemgain=false;

/*
 * Macro template to process multiple images in a folder
 * By B.van den Broek, R.Harkes & L.Nahidi
 * 06-06-2019
 * 
 * Changelog
 * 1.1:  weighted least squares, threshold to 2*std(Wave.F1)
 * 1.2:  error at square brackets, restructure for multi-image .lif, automatic wavelength detection from .lif files
 *       optional chromatic abberation correction enables automatic detection of wavelenth and corresponding affine transformation
 * 1.3:  Save Settings to .JSON file    
 * 1.31: Added automatic merging
 * 1.32: Fixed a bug concerning chromatic aberration (crash ifit was not applied)
 * 1.4:  Changed default filtering string from uncertainty_xy to uncertainty.
         Replace / with // in the filepath for JSON output.
         Add visualization method as option
 * 1.41  Option to convert to 16-bit
 *       Rendering on the same size as the image
 *       Fixed gaussian width (dx) for normalized gaussian rendering.
 * 2.0   Change affine transform to work with .json files
 * 2.1   Added features to be set in the GUI: fitting method, drift correction, displaying analysis boolean
 *       Various small improvements
 * 2.11  wavelength was undefined for .tiff files
 * 2.12  fixed temporal median background subtraction. (was broken in 2.1 and 2.11)
 * 2.13  fixed two JSON mistakes
 * 2.14  Added input parameters pixel_size and EM_gain in case the file extension is *not* .lif (e.g. no metadata retreival)
 * 2.15  JSON does not understand NaN (nor does it know infinite or -infinite). So we make it null.
 * 2.16  No Renderer also means not saving the TS image. 
 * 2.2   Change default_EM_Gain
 *       Allow fitradius and filtersettings in GUI
 *       Visualization after chromcorr was still average shifted histogram
 * 2.21  Wrong options in fitradius and peakthreshold
 * 2.22  ts_threshold was wrongly ts_method
 * 2.30  Save RAW-csv and filtered-csv. Affine transform on filtered-csv data.
 * 2.40  Use new ImageJSON plugin for writing json
 * 2.41  Forgot [] around the file.
 */
Version = 2.41;

//VARIABLES

//Camera Setup
readoutnoise=0;
quantumefficiency=1;

//Background Subtraction
window = 501;
if (Bool_TempMed){
	offset = 1000;
} else {
	offset=100;
}
//Thunderstorm
ts_filter = "Wavelet filter (B-Spline)";
ts_scale = 2;
ts_order = 3;
ts_detector = "Local maximum";
ts_connectivity = "8-neighbourhood";
//ts_threshold = set in GUI
//ts_estimator = set in GUI
ts_sigma = 1.2;
//ts_fitradius = set in GUI
//ts_method = set in GUI
ts_full_image_fitting = false;
ts_mfaenabled = false;
//ts_renderer = set in GUI
ts_magnification = 10;
ts_colorize = false;
ts_threed = false;
ts_shifts = 2;
ts_repaint = 50;
ts_floatprecision = 5;
affine = "";
ts_drift_magnification = 5;
//ts_drift_steps = set in GUI

Bool_debug = false;

//Location of the folder containing the JSON chromatic aberration files
affine_transform_532 = jsondir + File.separator + "AffineTransform532.json";
affine_transform_488 = jsondir + File.separator + "AffineTransform488.json";

if(!File.exists(output)) {
	create = getBoolean("The specified output folder "+output+" does not exist. Create?");
	if(create==true) File.makeDirectory(output);		//create the output folder if it doesn't exist
	else exit;
}

print("---AUTOMATIC THUNDERSTORM ANALYSIS---")
;
if(Bool_display==false) setBatchMode(true);
processFolder(input);
if(nImages>0) run("Close All");
setBatchMode(false);

// function to scan folders/subfolders/files to find files with correct suffix
function processFolder(input) {
	list = getFileList(input);
	list = Array.sort(list);
	for (i = 0; i < list.length; i++) {
	input_path = input + File.separator + list[i];
		if(File.isDirectory(input_path) && (substring(input_path,0,lengthOf(input_path)-1) != output)
)	//Skip folder if it is the output folder
			processFolder(input_path);
		if(endsWith(list[i], suffix))
			processFile(input, output, list[i]);
	}
}

function processFile(input, output, file) {
	inputfile = input + File.separator + file ;
	outputcsv = output + File.separator + substring(file,0, lengthOf(file)-lengthOf(suffix)) + ".csv";	
	outputtiff = output+File.separator+substring(file,0, lengthOf(file)-lengthOf(suffix)) + "_TS.tif";
	print("Processing file "+inputfile);
	if (matches(inputfile,".*[\\[|\\]].*")){ //no square brackets
		print("ERROR: Square brackets in file or foldernames are not supported by ThunderSTORM.");
		exit();
	}
	//open file using Bio-Formats
	run("Bio-Formats Macro Extensions");
	Ext.setId(inputfile);
	Ext.getSeriesCount(nr_series);
	for(n=0;n<nr_series;n++) {
		Ext.setSeries(n);	//numbering apparently starts at 0...
		Ext.getSizeT(sizeT);
		Ext.getSizeZ(sizeZ);
		Ext.getSeriesName(seriesName);
		
		if((sizeT>1) || (sizeZ>1&&suffix!="lif") || (sizeZ>1&&suffix!=".lif")) {
			if (nr_series>1){ //feedback & renaming of the outputfiles
				print("Processing file "+inputfile+" ; series "+n+1+"/"+nr_series);
				if(n==0){
					outputcsv_base=substring(outputcsv,0, lengthOf(outputcsv)-lengthOf(suffix));
					outputtiff_base=substring(outputtiff,0, lengthOf(outputtiff)-lengthOf(suffix));
				}
				outputcsv = outputcsv_base + "_series" + n+1 + ".csv";
				outputtiff= outputtiff_base + "_series" + n+1 + ".tif";
			}
			print("Thunderstorm Result in: " + outputcsv);
			run("Close All");
			run("Bio-Formats Importer", "open=[" + inputfile + "] autoscale color_mode=Default view=Hyperstack stack_order=XYCZT series_"+n+1);
			
			getPixelSize(unit,pixel_size_image,pixel_size_image);
			if(unit=="microns"||unit=="micron"||unit=="um"){
				pixel_size = pixel_size_image*1000;	//set pixel size in nm
				print("pixel size found: "+pixel_size+" nm\n");
			}
			else print("Warning: pixel size not found. Assuming "+pixel_size+" nm.\n");
			if (endsWith(suffix,"lif")){  //Get info from metadata of the .lif file
				Ext.getSeriesMetadataValue("Image|ATLCameraSettingDefinition|WideFieldChannelConfigurator|WideFieldChannelInfo|FluoCubeName",wavelength); //get wavelength
				if(Bool_ChromCorr&&wavelength!=0) {
					print("Wavelength found in metadata: "+wavelength+" nm");
				}
				Ext.getSeriesMetadataValue("Image|ATLCameraSettingDefinition|CanDoEMGain",isemgain); //set to true if the caemra has EM gain
				Ext.getSeriesMetadataValue("Image|ATLCameraSettingDefinition|EMGainValue",EM_gain); //get EM gain
			}else if (Bool_ChromCorr){
				wavelength = substring(file,lengthOf(file) - lengthOf(suffix) - 3, lengthOf(file) - lengthOf(suffix)); //get wavelength from last three characters of the filename
			}else {
				wavelength = '';
			}
			run("Camera setup", "readoutnoise="+readoutnoise+" offset="+offset+" quantumefficiency="+quantumefficiency+" isemgain="+isemgain+" photons2adu="+photons2adu+" gainem="+EM_gain+" pixelsize="+pixel_size);
			if (Bool_TempMed){
				run("Temporal Median Background Subtraction", "window="+window+" offset="+offset);
			}
			processimage(outputtiff, outputcsv, wavelength, EM_gain, pixel_size);
		}
	}	
}

function processimage(outputtiff, outputcsv, wavelength, EM_gain, pixel_size) {
	//save general settings (JSON)
	jsonfile = substring(outputcsv,0,lengthOf(outputcsv)-4) + "_TS.json";
	run("ImageJSON", "file=["+jsonfile+"] command=create name= value=");
	
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[SR Macro Version] value="+Version);
	run("ImageJSON", "file=["+jsonfile+"] command=string name=[Date] value=["+getDateTime()+"]");
	run("ImageJSON", "file=["+jsonfile+"] command=string name=[File] value=["+file+"]");
	run("ImageJSON", "file=["+jsonfile+"] command=string name=[File Location] value=["+input+"]");
	
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Super Resolution Post Processing Settings] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Temporal Median Filtering] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Applied] value="+Bool_ChromCorr);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Window] value="+window);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Offset] value="+offset);
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
    //Image Info
    IMwidth = getWidth;
  	IMheight = getHeight;
	
	run("Run analysis", "filter=["+ts_filter+"] scale="+ts_scale+" order="+ts_order+" detector=["+ts_detector+"] connectivity=["+ts_connectivity+"] threshold=["+ts_threshold+
	  "] estimator=["+ts_estimator+"] sigma="+ts_sigma+" fitradius="+ts_fitradius+" method=["+ts_method+"] full_image_fitting="+ts_full_image_fitting+" mfaenabled="+ts_mfaenabled+
	  " renderer=["+ts_renderer+"] magnification="+ts_magnification+" colorize="+ts_colorize+" threed="+ts_threed+" shifts="+ts_shifts+" repaint="+ts_repaint);
	outputcsvRAW = substring(outputcsv,0,lengthOf(outputcsv)-4) + "_RAW.csv";
	run("Export results", "floatprecision="+ts_floatprecision+" filepath=["+ outputcsvRAW + "] fileformat=[CSV (comma separated)] sigma=true intensity=true offset=true saveprotocol=false x=true y=true bkgstd=true id=true uncertainty_xy=true frame=true");
	
	//save the ThunderStorm settings (JSON)
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[ThunderStorm Settings] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Camera Settings] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[offset] value="+offset);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[quantumefficiency] value="+quantumefficiency);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[emgain] value="+isemgain);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[readoutnoise] value="+readoutnoise);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[photons2adu] value="+photons2adu);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[emgain level] value="+EM_gain);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[pixelsize] value="+pixel_size);
		run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
		
		run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Image filtering] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[filter] value=["+ts_filter+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[scale] value="+ts_scale);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[order] value="+ts_order);
		run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
		run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Approximate localization of molecules] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[detector] value=["+ts_detector+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[connectivity] value=["+ts_connectivity+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[threshold] value=["+ts_threshold+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
		run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Sub-pixel localization of molecules] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[estimator] value=["+ts_estimator+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[sigma] value="+ts_sigma);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[fitradius] value="+ts_fitradius);
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[method] value=["+ts_method+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[full image fitting] value="+ts_full_image_fitting);
		run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[multi-emitter fitting analysis enabled] value="+ts_mfaenabled);
		run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");

		run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Visualization of the results] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=string name=[renderer] value=["+ts_renderer+"]");
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[magnification] value="+ts_magnification);
		run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[colorize] value="+ts_colorize);
		run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Three Dimensional] value="+ts_threed);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[Lateral shifts] value="+ts_shifts);
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[Update Frequency] value="+ts_repaint);
		run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
		
		run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Output] value=");
		run("ImageJSON", "file=["+jsonfile+"] command=number name=[csv float precision] value="+ts_floatprecision);
		run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");		
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");

	//Drift correction
	if (Bool_DriftCorr) {
		run("Show results table", "action=drift magnification="+ts_drift_magnification+" method=[Cross correlation] ccsmoothingbandwidth=0.25 save=false steps="+ts_drift_steps+" showcorrelations=false");
		selectWindow("Drift");
		outputtiff_drift = substring(outputtiff,0,lengthOf(outputtiff)-4) + "_drift.tif";
		saveAs("Tiff", outputtiff_drift);
		close();
	}
	// save drift correction settings
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Drift correction] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Applied] value="+Bool_DriftCorr);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Magnification] value="+ts_drift_magnification);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Steps] value="+ts_drift_steps);
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
	//Merge reappearing molecules
	AutoMerge_ZCoordWeight=0.1;
	AutoMerge_OffFrame=1;
	AutoMerge_Dist=20;
	AutoMerge_FramesPerMolecule=0;
	if (Bool_AutoMerge) {
		run("Show results table", "action=merge zcoordweight="+AutoMerge_ZCoordWeight+" offframes="+AutoMerge_OffFrame+" dist="+AutoMerge_Dist+" framespermolecule="+AutoMerge_FramesPerMolecule);
	}
	// save merge settings
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Merging of reappearing molecules] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Applied] value="+Bool_AutoMerge);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Z coordinate weight] value="+AutoMerge_ZCoordWeight);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Maximum off frames] value="+AutoMerge_OffFrame);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Maximum distance] value="+AutoMerge_Dist);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Maximum frames per molecule] value="+AutoMerge_FramesPerMolecule);
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
    //Filtering
	if (filtering_string != "") {
		run("Show results table", "action=filter formula=[" + filtering_string + "]");
	}
	run("Export results", "floatprecision="+ts_floatprecision+" filepath=["+ outputcsv + "] fileformat=[CSV (comma separated)] sigma=true intensity=true offset=true saveprotocol=false x=true y=true bkgstd=true id=true uncertainty_xy=true frame=true");
	// save filtering settings
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Filtering] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=string name=[Filtering string] value=["+filtering_string+"]");
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
	//rendering
	rd_force_dx = true;
	rd_dx=10;
	rd_dzforce=false;
	run("Visualization", "imleft=0.0 imtop=0.0 imwidth="+IMwidth+" imheight="+IMheight+" renderer=["+ts_renderer+"] dxforce="+rd_force_dx+" magnification="+ts_magnification+" colorize="+ts_colorize+" dx="+rd_dx+" threed="+ts_threed+" dzforce="+rd_dzforce);
	// save rendering settings
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Rendering] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Force dx] value="+rd_force_dx);
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[dx] value="+rd_dx);
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Force dz] value="+rd_dzforce);
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");
	
	if(Bool_16bit){
		run("Conversions...", "scale");
		resetMinAndMax();
		run("16-bit");
	}
	saveAs("Tiff", outputtiff);

	//Chromatic Aberration Correction
	if (Bool_ChromCorr){
		print("wavelength = " + wavelength + " nm");
		if (wavelength == "642"){
			affine = "";
		}else if (wavelength == "532") {
			affine = affine_transform_532;
		}else if (wavelength == "488") {
			affine = affine_transform_488;
		}else {
			print("\\Update:Warning: unknown wavelength ("+wavelength+" nm). No chromatic aberration correction will be applied");
			wavelength="";
			affine = "";
		}
	
		if (affine!="") {
			run("Close All");
			outputcsv2 = substring(outputcsv,0,lengthOf(outputcsv)-4) + "_chromcorr.csv";
			print("Chromatic Abberation corrected result in: " + outputcsv2);
			run("Do Affine", "csvfile1=["+ outputcsv +"] csvfile2=["+ outputcsv2 + "] affine_file=["+affine+"]");
			run("Import results", "detectmeasurementprotocol=false filepath=["+ outputcsv2 + "] fileformat=[CSV (comma separated)] livepreview=false rawimagestack= startingframe=1 append=false");
			run("Visualization", "imleft=0.0 imtop=0.0 imwidth="+IMwidth+" imheight="+IMheight+" renderer=["+ts_renderer+"] dxforce="+rd_force_dx+" magnification="+ts_magnification+" colorize="+ts_colorize+" dx="+rd_dx+" threed="+ts_threed+" dzforce="+rd_dzforce);
			outputtiff_chromcorr = substring(outputtiff,0,lengthOf(outputtiff)-4) + "_chromcorr.tif";
			if(Bool_16bit){
				run("Conversions...", "scale");
				resetMinAndMax();
				run("16-bit");
			}
			saveAs("Tiff", outputtiff_chromcorr);
		}
	}
	// save Chromatic Aberration Correction settings
	run("ImageJSON", "file=["+jsonfile+"] command=objStart name=[Chromatic Abberation Correction] value=");
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Requested] value="+Bool_ChromCorr);
	run("ImageJSON", "file=["+jsonfile+"] command=boolean name=[Applied] value="+(affine!=""));
	run("ImageJSON", "file=["+jsonfile+"] command=number name=[Wavelength] value="+wavelength);
	run("ImageJSON", "file=["+jsonfile+"] command=string name=[Applied Affine Transform] value=["+affine+"]");
	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value=");

	run("ImageJSON", "file=["+jsonfile+"] command=objEnd name= value="); //end of [Super Resolution Post Processing Settings]
	run("ImageJSON", "file=["+jsonfile+"] command=close name= value=");
}

function getDateTime() {
     MonthNames = newArray("Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec");
     DayNames = newArray("Sun", "Mon","Tue","Wed","Thu","Fri","Sat");
     getDateAndTime(year, month, dayOfWeek, dayOfMonth, hour, minute, second, msec);
     TimeString =DayNames[dayOfWeek]+" ";
     if (dayOfMonth<10) {TimeString = TimeString+"0";}
     TimeString = TimeString+dayOfMonth+"-"+MonthNames[month]+"-"+year+" @ ";
     if (hour<10) {TimeString = TimeString+"0";}
     TimeString = TimeString+hour+":";
     if (minute<10) {TimeString = TimeString+"0";}
     TimeString = TimeString+minute+":";
     if (second<10) {TimeString = TimeString+"0";}
     TimeString = TimeString+second;
     return TimeString;
}