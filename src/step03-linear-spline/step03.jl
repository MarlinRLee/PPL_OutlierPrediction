"""
This block of code loads the jl files and extracts the xs, ys from appropriate columns of data
"""

using  Gen
using Plots

include("../step01-importing-data/utilities/read-files.jl")
DF = ReadDF("../../data/processed/DetrendedCov.csv")
xs = DF.Date
ys = DF.N1
include("../step02-linear-model/utilities/visualize.jl")

"""
This function divides subchunks into 35 data points.
"""
SubChunkSize = 35#Number of points per chunk
function DiffrenceIndex(i::Int)#helper function to find out what chunk a point is in
    return(div(i,SubChunkSize,RoundUp))
end

"""
This function calculates the slope and model for the linear spline model.
"""
function yValCalc(xs::Vector{Float64}, Buffer_y::Float64, Slopes::Vector{Float64})
    n = length(xs)
    NumChunks = DiffrenceIndex(n)


    #calculating the 'y intercept' of each chunk to make sure each line connects to the last one
    #Because each intercept gets added to the last one we take the cumulative sum to get the total ofset needed at each step
    #The first value should be the initial ofset Buffer_y to get everything aligned
    #ysOfseted = [Buffer_y, Slope[chunk](x[chunk]- x[Last chunk])]
    ysOfseted = cumsum(pushfirst!([Slopes[i]*(xs[(i)*SubChunkSize] - xs[(i-1)*SubChunkSize+1]) for i=1:(NumChunks-1)],Buffer_y))
    
    
    #calculates the change of y from the previous chunk to the current x. We combine this with a set of y ofset values
    #in the next step to get the true mu fed into the normal distribution
    #TrueDeltaMu n = Slope[chunk](x[i]- x[Last chunk])
    TrueDeltaMu = [Slopes[DiffrenceIndex(i)]*(xs[i] - xs[div(i-1,SubChunkSize,RoundDown)*SubChunkSize+1]) for i=1:n]
    ys = [TrueDeltaMu[i] + ysOfseted[DiffrenceIndex(i)] for i=1:n]
end

"""
This function defines the parameters like the outlier, slope, noise. It models linear spline model with the parameters defined.
"""
@gen function Linear_Spline_with_outliers(xs::Vector{<:Real})
    #First we calculate some useful values needed for the list comprehension in the next steps
    n = length(xs)
    NumChunks = DiffrenceIndex(n)

    # Next, we generate some parameters of the model. There are three types of randomly made perameters. First are the constant ones
    #That are unique to the process. These are generated first.
    #Second are the ones that are unique to the individual chunks. These loop from 1 to NumChunks
    #Last are the ones that vary for every point. These range from 1 to n


    #Unique to process

    #Where the series starts. In the log model this is around 12 and I give it a pretty big window
    Buffer_y ~ gamma(200, 200)
    
    #the probability any given point is a outlier
    prob_outlier ~ uniform(.05, .1)

    #The scaling factor on outliers:
    OutlierDeg ~ uniform(1, 5)
    
    #unique to chunk

    #The data apears to have no slope over 3 so a sd of 2 should capture the true slopes with high probability
    Slopes = [{(:slope, i)} ~ normal(0, 3000) for i=1:NumChunks]

    #The distribution of the noise. It gets fed into the sd of a normal distribution so the distribution of the noise needs to be always positive
    noise = [{(:noise, i)} ~ gamma(150, 150) for i=1:NumChunks]
   

    #EveryPoint

    #is using the prob_outlier vector above to decide if each point is an outlier. the model we are using now has 
    #The slope and sd $OutlierDeg times larger then the non outliers. so we times the mu and sd by this value in the last step
    PointOutlier = ((OutlierDeg-1)*[{:data => i => :is_outlier} ~ bernoulli(prob_outlier) for i=1:n] .+ 1)

    
    
    
    TrueVec = yValCalc(xs,Buffer_y,Slopes)
    ys = [{:data => i => :y} ~ 
        normal(
            TrueVec[i] * PointOutlier[i],            #mean of normal rand var
            noise[DiffrenceIndex(i)]                 #var of normal rand var
        ) 
        for i=1:n]
    ys
end

"""
This function defines the necessary dictionary for plotting our data and the spline model.
"""
#Get seralize trace to accept function instaed of unique code for each version
function serialize_trace(trace)
    (xs,) = Gen.get_args(trace)
    n = length(xs)
    NumChunks = div(n, SubChunkSize, RoundUp)
    slopes = [trace[(:slope, i)] for i in 1:NumChunks]
    FlatDict = Dict(
          :points => zip(xs, [trace[:data => i => :y] for i in 1:n]),
          :outliers => [trace[:data => i => :is_outlier] for i in 1:n],
         :xs => xs,
         :ys => yValCalc(xs, trace[:Buffer_y], slopes))
    return(FlatDict)
end

"""
Visualize the spline model that we have created.
"""
VizGenModel(Linear_Spline_with_outliers)

"""
This assigns the necessary dictionary information into variable named observations. It correctly loads the csv file data.
"""
observations = make_constraints(ys);

"""
This is visualizing our csv data with the model that we created.
"""
VizGenMCMC(Linear_Spline_with_outliers, xs, observations,block_resimulation_update,300)
