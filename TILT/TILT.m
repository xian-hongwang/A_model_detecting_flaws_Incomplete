% % Modified by Xian-Hong Wang June 2023.
% Based on published code TILT_v1.03 by Kelvin Zhang, Arvind Ganesh,
% February 2011. 
%
% Reference: Linearized Alternating Direction Method with Adaptive Penalty
%            for Fast Solving Transform Invariant Low-rank Texture.
%            Xiang Ren, Zhouchen Lin. Submitted to IJCV.
%
%            TILT: Transform Invariant Low-rank Textures  
%            Zhengdong Zhang, Xiao Liang, Arvind Ganesh, and Yi Ma. Proc. of ACCV, 2010.
%

function [Dotau, A, E, f, tfm_matrix, focus_size, error_sign, UData, VData, XData, YData, A_scale]=TILT(varargin)
% Version info: v 1.03
% -------------------------------------------------------------------------
% Update: 1.change the action of branch-and-bound from running TILT at each
%         guessing configuration to calculate and compare f at each
%         configuration. As a benefit, we can branch-and-bound more
%         carefully.
%         2.fine tune the parameters for inner-loop, and outer-loop.
%         3.Also the interface is slightly changed, mainly the setting of
%         co-ordinates.
% -------------------------------------------------------------------------
% 
% TILT will align the drawn-part of the image to its frontal.
% TILT is built on the kernel_component tilt_kernel.
% TILT(input_image, mode, based_points, focus_size) is the simplest form of
% the parameter, and these four parameters must be specified. There are
% also many other optional parameters.
%
% ----------------------necessary input------------------------------------
% input_image:  height-by-width real matrix or height*width*3 real matrix but
%               we will only preserve the first channel for the second
%               case.
% mode:         one of 'euclidean', 'affine', 'homography'.
% 
% [note]: One of the following sets of parameters must be specified.
% Set 1: initial_points:  
%               2-by-1 real vector in x-y co-ordinates, top-left point of
%               the focus. In this situation our algorithm will
%               automatically decide the UData, VData, XData and YData as
%               the output.
% Set 2: UData, VData, XData and YData.
%               All 1-by-2 real vector. These specifying the coordinate of
%               the input image and the transformed image, and we'll work
%               in this coordinate system by default.
% 
% ----------------------optional parameters--------------------------------
% INITIAL_MATRIX:   3-by-3 initialization matrix for tfm_matrix. If this is
%                   not set, tfm_matrix will be initialized to identity.
% BRANCH:           0 or 1, 1 for turnning on branch-and-bound, but this is
%                   only allowed in the AFFINE case.
% BLUR:             0 or 1, 1 for turnning on BLUR.
% PYRAMID:          0 or 1, 1 for turnning on pyramid.
% NO_TRANSLATION:   0 or 1, 1 for no translation.
% 
% INNER_C:          positive real value, inner_loop lambda=C/sqrt(m).
% INNER_MU:         positive real value, inner_loop for ALM mu.
% INNER_MAXITER:    positive integer, maximum iteration for inner_loop.
% INNER_DISPLAY:    positive integer, whether we display the results.
% OUTER_TOL:        positive real value, outer_loop threshold.
% OUTER_MAXITER:    positive integer, maximum iteration for outer_loop.
% OUTER_DISPLAY:    positive integer, whether we display the results for
%                   the outer loop.
% FOCUS_THRE:       positive integer, smallest edge length threshold in
%                   pyramid
% OUTER_TOL_STEP:   positive real value, We relax threshold for
%                   outer-loop each time we move downstairs in pyramid
%                   by tol=tol*OUTER_TOL_STEP
% BLUR_SIGMA:       positive real value, standard derivation of the blur
%                   kernel.
% BLUR_NEIGHBOR:    positive integer, size of effective blur neighbourhood.
% BRANCH_MAXITER:   positive integer, we need have extremely high accuracy
%                   in branch-andbound. So we separately set
%                   branch_maxiter for branch_and_bound.
% BRANCH_ACCURACY:  positive integer, we split the whole parameter region
%                   to search into 2*branch_accuracy+1 sub-region.
% BRANCH_MAX_ROTATION:
%                   positive real, by default pi/8, specifying how large to
%                   do branch-and-bound for rotation.
% BRANCH_MAX_SKEW:
%                   positive, real, by default 
% PYRAMID_MAXLEVEL: positive integer, we only run TILT on the highest
%                   PYRAMID_MAXLEVEL levels in the pyramid.
% DISPLAY_INTER:    0 or 1, whether we display results for every call to
%                   tilt_kernel.m
% FOCUS_SIZE:       1*2 row vector, forcing focus_size to be something.
% SAVE_PATH:        string, full path of where to save the results.
% 
% -------------------------output------------------------------------------
% Dotau:        real matrix with same size as focus_size, aligned images.
% A:            low-rank part of Dotau;
% E:            sparse-error part of Dotau;
% f:            value of objective-function;
% tfm_matrix:   resulted transform matrix.
% focus_size:   1*2 positive integer vector, size of the focus window in
%               r-c coordinate.
% error_sign:   0 or 1, 1 for trival solutions.
% UData, VData: 1*2 real vector, position of the input image.
% XData, YData: 1*2 real vector, position of the transformed image.

args=parse_inputs(varargin{:});
parent_path=args.save_path;
initial_tfm_matrix=args.initial_tfm_matrix;
original_tfm_matrix=args.initial_tfm_matrix; % record it for plotting the initial configuration in final result.
if ~exist(args.save_path) || ~isdir(args.save_path)
    mkdir(args.save_path);
end
if args.branch==1
    %% Branch-and-bound if set
    %% step 1: prepare data for the lowest resolution.
    total_scale=floor(log2(min(args.focus_size)/args.focus_threshold));
    downsample_matrix=[0.5 0 0; 0 0.5 0; 0 0 1];
    scale_matrix=downsample_matrix^total_scale;
    tfm=maketform('projective', scale_matrix');
    if args.blur
       %% blur if set
        input_image=imfilter(args.input_image, fspecial('gaussian', ceil(args.blur_kernel_size_k*2^total_scale), ceil(args.blur_kernel_sigma_k*2^total_scale)));
    else
        input_image=args.input_image;
    end
    input_image=imtransform(input_image, tfm, 'bicubic');
    if size(input_image, 3)>1
        input_image=rgb2gray(input_image);
    end
    input_image=double(input_image);
    initial_tfm_matrix=scale_matrix*args.initial_tfm_matrix*inv(scale_matrix);
    center=floor(transform_point(args.center, scale_matrix));
    focus_size=floor(args.focus_size/2^total_scale);
    f_branch=zeros(3, 2*args.branch_accuracy+1);
    A_branch=cell(3, 2*args.branch_accuracy+1);
    E_branch=cell(3, 2*args.branch_accuracy+1);
    Dotau_branch=cell(3, 2*args.branch_accuracy+1);
    result_tfm_matrix=cell(3, 2*args.branch_accuracy+1);
    %% step 2: design branch-and-bound method.
    switch lower(args.mode)
        case {'affine', 'homography'}
            max_rotation=args.branch_max_rotation;
            max_skew=args.branch_max_skew;
            level=3;
            candidate_matrix=cell(3, 2*args.branch_accuracy+1);
            for i=1:2*args.branch_accuracy+1
                candidate_matrix{1, i}=eye(3);
                theta=-max_rotation+(i-1)*max_rotation/args.branch_accuracy;
                candidate_matrix{1, i}(1:2, 1:2)=[cos(theta) -sin(theta); sin(theta) cos(theta)];
                candidate_matrix{2, i}=eye(3);
                candidate_matrix{2, i}(1, 2)=-max_skew+(i-1)*max_skew/args.branch_accuracy;
                candidate_matrix{3, i}=eye(3);
                candidate_matrix{3, i}(2, 1)=-max_skew+(i-1)*max_skew/args.branch_accuracy;
            end
    end
    gap=5;
    BLACK_MATRIX=zeros(focus_size(1)*level+gap*(level-1), focus_size(2)*(2*args.branch_accuracy+1)+gap*2*args.branch_accuracy);
    %% step 3: begin branch-and-bound
    normal_outer_max_iter=args.outer_max_iter;
    normal_display_inter=args.display_result;
    args.outer_max_iter=1; % for debug, set it to 1;
    args.display_result=0;
    fprintf('Do branching: ');
    for i=1:level
        for j=1:2*args.branch_accuracy+1
           tfm_matrix=inv(candidate_matrix{i, j}*inv(initial_tfm_matrix));
           args.figure_no=(i-1)*level+j;
           args.save_path=[];
%            [Dotau, A, E, f, tfm_matrix, error_sign, UData, VData, XData, YData, A_scale]=tilt_kernel(input_image, args.mode, center, focus_size, tfm_matrix, args);
           %% update 1: assume that there's no great error, we directly
           %% compute nuclear norm of Dotau as the selection criterion;
           %% record result
            image_size=size(input_image);
            image_center=floor(center);
            focus_center=zeros(2, 1);
            focus_center(1)=floor((1+focus_size(2))/2);
            focus_center(2)=floor((1+focus_size(1))/2);
            UData=[1-image_center(1) image_size(2)-image_center(1)];
            VData=[1-image_center(2) image_size(1)-image_center(2)];
            XData=[1-focus_center(1) focus_size(2)-focus_center(1)];
            YData=[1-focus_center(2) focus_size(1)-focus_center(2)];
            tfm=fliptform(maketform('projective', tfm_matrix'));
            Dotau=imtransform(input_image, tfm, 'bilinear', 'XData', XData, 'YData', YData, 'UData', UData, 'VData', VData, 'Size', focus_size);
            Dotau=Dotau/norm(Dotau, 'fro');
            [U S V]=svd(Dotau);
            f=sum(sum(S));
            fprintf('.');
%            disp(['branching: level=', num2str(i), ', idx=', num2str(j)]);
           start=[(focus_size(1)+gap)*(i-1)+1, (focus_size(2)+gap)*(j-1)+1];
           BLACK_MATRIX(start(1):(start(1)+focus_size(1)-1), start(2):(start(2)+focus_size(2)-1))=Dotau;
           f_branch(i, j)=f;
%            A_branch{i, j}=A;
%            E_branch{i, j}=E;
           Dotau_branch{i, j}=Dotau;
           result_tfm_matrix{i, j}=tfm_matrix;
        end
        [value index]=min(f_branch(i, :));
        initial_tfm_matrix=result_tfm_matrix{i, index};
    end
    fprintf('\n');
    %% step 4: adapt initial_tfm_matrix to highest-resolution.
    initial_tfm_matrix=inv(scale_matrix)*initial_tfm_matrix*scale_matrix;
    
    %% step 5: show inter result if necessary.
    if normal_display_inter==1
        showimage(BLACK_MATRIX, 98);
    end
    args.outer_max_iter=normal_outer_max_iter;
    args.display_result=normal_display_inter;
end

%% Do pyramid if necessary
if args.warmstart == 1
    disp(['With Warmstart ']);
else
    disp(['No Warmstart ']);
end
t_sum = 0;
if args.pyramid==1
    %% define parameters
    downsample_matrix=[0.5 0 0; 0 0.5 0; 0 0 1];
    upsample_matrix=inv(downsample_matrix);
    total_scale=ceil(max(log2(min(args.focus_size)/args.focus_threshold), 0));
    for scale=total_scale:-1:0
        %% begin each level of the pyramid
        if total_scale-scale>=args.pyramid_max_level
            break;
        end
        %% Blur if required
        if args.blur==1 && scale~=0
            input_image=imfilter(args.input_image, fspecial('gaussian', ceil(args.blur_kernel_size_k*2^scale), ceil(args.blur_kernel_sigma_k*2^scale)));
        else
            input_image=args.input_image;
        end
        
        %% prepare image and initial tfm_matrix
        scale_matrix=downsample_matrix^scale;
        tfm=maketform('projective', scale_matrix');
        input_image=imtransform(input_image, tfm, 'bicubic');
        tfm_matrix=scale_matrix*initial_tfm_matrix*inv(scale_matrix);
        center=floor(transform_point(args.center, scale_matrix));
        focus_size=floor(args.focus_size/2^scale);
        args.save_path=fullfile(parent_path, ['pyramid', num2str(scale)]);
        args.figure_no=100+total_scale-scale+1;
        [Dotau, A, E, f, tfm_matrix, error_sign, UData, VData, XData, YData, A_scale, t]=tilt_ladmws(input_image, args.mode, center, focus_size, tfm_matrix, args);
        %% update tfm_matrix of the highest-resolution level.
        initial_tfm_matrix=inv(scale_matrix)*tfm_matrix*scale_matrix;
        args.outer_tol=args.outer_tol*args.outer_tol_step;
        t_sum = t_sum+t;
    end
    disp(['Total algorthm time: ' num2str(t_sum)]);
    tfm_matrix=initial_tfm_matrix;
else
    %% No Pyramid
    
    %% Blur if required
    if args.blur==1
        img_size=size(args.input_image);
        img_size=img_size(1:2);
        input_image=imfilter(args.input_image, fspecial('gaussian', ceil(args.blur_kernel_size_k*max(img_size)/50), ceil(args.blur_kernel_sigma_k*max(img_size)/50)));
    else
        input_image=args.input_image;
    end
    args.figure_no=101;
    args.save_path=fullfile(parent_path, 'pyramid0');
    [Dotau, A, E, f, tfm_matrix, error_sign, UData, VData, XData, YData, A_scale, t]=...
        tilt_ladmws(input_image, args.mode, args.center, args.focus_size, args.initial_tfm_matrix, args);
    disp(['Total algorthm time: ' num2str(t)]);

end


focus_size=args.focus_size;
image_size=size(args.input_image);
image_size=image_size(1:2);
image_center=args.center;
focus_center=zeros(2, 1);
focus_center(1)=floor((1+args.focus_size(2))/2);
focus_center(2)=floor((1+args.focus_size(1))/2);
UData=[1-image_center(1) image_size(2)-image_center(1)];
VData=[1-image_center(2) image_size(1)-image_center(2)];
XData=[1-focus_center(1) args.focus_size(2)-focus_center(1)];
YData=[1-focus_center(2) args.focus_size(1)-focus_center(2)];

%% display the result.
if args.display_result==1
    %% display the frame in the original image.
    figure(99);
%     pt_top_left=transform_point([XData(1); YData(1)], args.initial_tfm_matrix)+image_center;
%     pt_bottom_left=transform_point([XData(1); YData(2)], args.initial_tfm_matrix)+image_center;
%     pt_bottom_right=transform_point([XData(2); YData(2)], args.initial_tfm_matrix)+image_center;
%     pt_top_right=transform_point([XData(2); YData(1)], tfm_matrix)+image_center;
    imshow(args.input_image, [], 'DisplayRange', [0 max(max(max(args.input_image)))]);
%     X1=[pt_top_left(1) pt_bottom_left(1) pt_bottom_right(1) pt_top_right(1) pt_top_left(1)];
%     Y1=[pt_top_left(2) pt_bottom_left(2) pt_bottom_right(2) pt_top_right(2) pt_top_left(2)];
%     hold on;
%     plot(X1, Y1, 'r-');
    X1=[args.initial_points(1,1) args.initial_points(1,1) args.initial_points(1,2) args.initial_points(1,2) args.initial_points(1,1)];
    Y1=[args.initial_points(2,1) args.initial_points(2,2) args.initial_points(2,2) args.initial_points(2,1) args.initial_points(2,1)];
    hold on;
    plot(X1, Y1, 'r-');
    pt_top_left=transform_point([XData(1); YData(1)], tfm_matrix)+image_center;
    pt_bottom_left=transform_point([XData(1); YData(2)], tfm_matrix)+image_center;
    pt_bottom_right=transform_point([XData(2); YData(2)], tfm_matrix)+image_center;
    pt_top_right=transform_point([XData(2); YData(1)], tfm_matrix)+image_center;
    X2=[pt_top_left(1) pt_bottom_left(1) pt_bottom_right(1) pt_top_right(1) pt_top_left(1)];
    Y2=[pt_top_left(2) pt_bottom_left(2) pt_bottom_right(2) pt_top_right(2) pt_top_left(2)];
    plot(X2, Y2, 'g-');

    %% display initial, Dotau, A, E
    figure(100);
    subplot(2, 2, 1);
    imshow(args.input_image);
    tfm=fliptform(maketform('projective', tfm_matrix'));
    aligned_focus=imtransform(args.input_image, tfm, 'bilinear', 'UData', UData, 'VData', VData, 'XData', XData, 'YData', YData, 'size', args.focus_size);
    subplot(2, 2, 2);
    if max(max(max(aligned_focus)))~=0
        imshow(aligned_focus);
    end
    subplot(2, 2, 3);
    if max(max(max(A)))~=0
        imshow(A, [], 'DisplayRange', [0 max(max(max(A)))]);
    end
    subplot(2, 2, 4);
    if max(max(max(E)))~=0
        imshow(E, [], 'DisplayRange', [0 max(max(max(E)))]);
    end
end

if ~isempty(parent_path)
    tfm=fliptform(maketform('projective', tfm_matrix'));
    Dotau_write=imtransform(args.input_image, tfm, 'bilinear', 'UData', UData, 'VData', VData, 'XData', XData, 'YData', YData, 'SIZE', focus_size);
    Dotau_full=imtransform(args.input_image, tfm, 'bilinear', 'UData', UData, 'VData', VData);
    imwrite(uint8(args.input_image), fullfile(parent_path, 'input_image.jpg'), 'JPEG');
    imwrite(uint8(Dotau_write), fullfile(parent_path, 'Dotau_color.jpg'), 'JPEG');
    imwrite(uint8(Dotau_full), fullfile(parent_path, 'Dotau_full.jpg'), 'JPEG');
    n_pt=4000;
    pt_step1=[XData(2)-XData(1); 0]/(n_pt-1);
    pt1=[XData(1); YData(1)]*ones(1, n_pt)+(pt_step1*(0:(n_pt-1)));
    pt_step2=[0; YData(2)-YData(1)]/(n_pt-1);
    pt2=[XData(2); YData(1)]*ones(1, n_pt)+(pt_step2*(0:(n_pt-1)));
    pt_step3=[XData(1)-XData(2); 0]/(n_pt-1);
    pt3=[XData(2); YData(2)]*ones(1, n_pt)+(pt_step3*(0:(n_pt-1)));
    pt_step4=[0; YData(1)-YData(2)]/(n_pt-1);
    pt4=[XData(1); YData(2)]*ones(1, n_pt)+(pt_step4*(0:(n_pt-1)));
    pt=[pt1 pt2 pt3 pt4];
    pt=[pt; ones(1, size(pt, 2))];
    image=args.input_image;
    if size(args.input_image, 3)==1
        image(:, :, 1)=args.input_image;
        image(:, :, 2)=args.input_image;
        image(:, :, 3)=args.input_image;
    end
    initial_pt=args.initial_tfm_matrix*pt;
    initial_pt(1, :)=floor(initial_pt(1, :)./initial_pt(3, :)+1-UData(1));
    initial_pt(2, :)=floor(initial_pt(2, :)./initial_pt(3, :)+1-VData(1));
    initial_pt=initial_pt(1:2, :);
    width_r=1;
    temp=[];
    for i=-width_r:width_r
        for j=-width_r:width_r
            temp=[temp initial_pt+[i; j]*ones(1, size(initial_pt, 2))];
        end
    end
    initial_pt=temp;
    initial_color=[255 0 0];
    for i=1:size(initial_pt, 2)
        if initial_pt(2, i)<1 || initial_pt(2, i)>size(args.input_image, 1) || initial_pt(1, i)<1 || initial_pt(1, i)>size(args.input_image, 2)
            continue;
        end
        for c=1:3
            image(initial_pt(2, i), initial_pt(1, i), c)=initial_color(c);
        end
    end
    
    final_pt=tfm_matrix*pt;
    final_pt(1, :)=floor(final_pt(1, :)./final_pt(3, :)+1-UData(1));
    final_pt(2, :)=floor(final_pt(2, :)./final_pt(3, :)+1-VData(1));
    final_pt=final_pt(1:2, :);
    temp=[];
    for i=-width_r:width_r
        for j=-width_r:width_r
            temp=[temp final_pt+[i; j]*ones(1, size(final_pt, 2))];
        end
    end
    final_pt=temp;
    final_color=[0 255 0];
    for i=1:size(final_pt, 2)
        if final_pt(2, i)<1 || final_pt(2, i)>size(args.input_image, 1) || final_pt(1, i)<1 || final_pt(1, i)>size(args.input_image, 2)
            continue;
        end
        for c=1:3
            image(final_pt(2, i), final_pt(1, i), c)=final_color(c);
        end
    end
    imwrite(uint8(image), fullfile(parent_path, 'plot.jpg'), 'JPEG');
    
    % option2: plot initial_points and homography.
    if size(args.initial_points, 2)==4
        args.initial_points=[args.initial_points(:, 1) args.initial_points(:, 3)];
    end
    image2=args.input_image;
    if size(args.input_image, 3)==1
        image2(:, :, 1)=args.input_image;
        image2(:, :, 2)=args.input_image;
        image2(:, :, 3)=args.input_image;
    end
    initial_pt=[];
    pt_step1=[args.initial_points(1, 2)-args.initial_points(1, 1); 0]/(n_pt-1);
    pt_step2=[0; args.initial_points(2, 2)-args.initial_points(2, 1)]/(n_pt-1);
    initial_pt=[initial_pt args.initial_points(:, 1)*ones(1, n_pt)+pt_step1*((0:(n_pt-1)))];
    initial_pt=[initial_pt [args.initial_points(1, 2); args.initial_points(2, 1)]*ones(1, n_pt)+pt_step2*((0:(n_pt-1)))];
    initial_pt=[initial_pt args.initial_points(:, 2)*ones(1, n_pt)-pt_step1*((0:(n_pt-1)))];
    initial_pt=[initial_pt [args.initial_points(1, 1); args.initial_points(2, 2)]*ones(1, n_pt)-pt_step2*((0:(n_pt-1)))];
    temp=[];
    for i=-width_r:width_r
        for j=-width_r:width_r
            temp=[temp initial_pt+[i; j]*ones(1, size(initial_pt, 2))];
        end
    end
    initial_pt=floor(temp);
    for i=1:size(initial_pt, 2)
        if initial_pt(2, i)<1 || initial_pt(2, i)>size(args.input_image, 1) || initial_pt(1, i)<1 || initial_pt(1, i)>size(args.input_image, 2)
            continue;
        end
        for c=1:3
            image2(initial_pt(2, i), initial_pt(1, i), c)=initial_color(c);
        end
    end
    
    final_pt=tfm_matrix*pt;
    final_pt(1, :)=floor(final_pt(1, :)./final_pt(3, :)+1-UData(1));
    final_pt(2, :)=floor(final_pt(2, :)./final_pt(3, :)+1-VData(1));
    final_pt=final_pt(1:2, :);
    temp=[];
    for i=-width_r:width_r
        for j=-width_r:width_r
            temp=[temp final_pt+[i; j]*ones(1, size(final_pt, 2))];
        end
    end
    final_pt=temp;
    final_color=[0 255 0];
    for i=1:size(final_pt, 2)
        if final_pt(2, i)<1 || final_pt(2, i)>size(args.input_image, 1) || final_pt(1, i)<1 || final_pt(1, i)>size(args.input_image, 2)
            continue;
        end
        for c=1:3
            image2(final_pt(2, i), final_pt(1, i), c)=final_color(c);
        end
    end
    imwrite(uint8(image2), fullfile(parent_path, 'plot2.jpg'), 'JPEG');
end

function args=parse_inputs(varargin)
iptchecknargin(3,Inf,nargin,mfilename);
%% default value
args.input_image=varargin{1};
args.mode=varargin{2};
args.initial_points=varargin{3};
args.initial_tfm_matrix=eye(3);
args.outer_tol=1e-4;
args.outer_max_iter=50;
args.outer_display_period=1;
args.inner_c=1;
args.inner_mu=[];
args.inner_display_period=100;
args.inner_max_iter=inf;
args.blur=1;
args.pyramid=1;
args.branch=(strcmp(lower(args.mode), 'affine'));
args.focus_threshold=50; % when doing pyramid the smallest focus_edge we can tolerate.
args.outer_tol_step=10; % as resolution goes high how relaxed should the outer_tol be.
args.blur_kernel_size_k=3;% neighbourhood scalar for the size of the blur kernel.
args.blur_kernel_sigma_k=3;% standard derivation scalar for blur kernel.
args.pyramid_max_level=2; % number of pyramid levels we want to act on.
args.branch_max_iter=10; % in each branch, how much iteration we take.
args.branch_accuracy=7; % higher means smaller step-width.
args.no_translation=1;
args.display_result=1;
args.focus_size=[];
args.save_path=[];
args.branch_max_rotation=pi/6;
args.branch_max_skew=1;
args.warmstart = 1;
args.svdws = 0;
for i=4:2:nargin
    switch(lower(varargin{i}))
        case 'outer_tol'
            args.outer_tol=varargin{i+1};
        case 'outer_maxiter'
            args.outer_max_iter=varargin{i+1};
        case 'outer_display'
            args.outer_display_period=varargin{i+1};
        case 'inner_mu'
            args.inner_mu=varargin{i+1};
        case 'inner_display'
            args.inner_display_period=varargin{i+1};
        case 'inner_maxiter'
            args.inner_max_iter=varargin{i+1};
        case 'inner_c'
            args.inner_c=varargin{i+1};
        case 'blur'
            args.blur=varargin{i+1};
        case 'pyramid'
            args.pyramid=varargin{i+1};
        case 'branch'
            args.branch=varargin{i+1};
        case 'focus_thre'
            args.focus_threshold=varargin{i+1};
        case 'outer_tol_step'
            args.outer_tol_step=varargin{i+1};
        case 'blur_sigma'
            args.blur_kernel_sigma_k=varargin{i+1};
        case 'blur_neighbor'
            args.blur_kernel_size_k=varargin{i+1};
        case 'pyramid_maxlevel'
            args.pyramid_max_level=varargin{i+1};
        case 'branch_maxiter'
            args.branch_max_iter=varargin{i+1};
        case 'branch_accuracy'
            args.branch_accuracy=varargin{i+1};
        case 'no_translation'
            args.no_translation=varargin{i+1};
        case 'initial_matrix'
            args.initial_tfm_matrix=varargin{i+1};
        case 'display_inter'
            args.display_result=varargin{i+1};
        case 'initial_points'
            args.initial_points=varargin{i+1};
        case 'focus_size'
            args.focus_size=floor(varargin{i+1});
        case 'save_path'
            args.save_path=varargin{i+1};
        case 'branch_max_rotation'
            args.branch_max_rotation=varargin{i+1};
        case 'branch_max_skew'
            args.branch_max_skew=varargin{i+1};
        case 'vws'
            args.warmstart = varargin{i+1};
        case 'svdws'
            args.svdws = varargin{i+1};   
    end
end
if args.no_translation==1
    args.mode=[args.mode, '_notranslation'];
end

%% do some initialization
if size(args.initial_points, 2)==2
    args.initial_points=floor(args.initial_points);
    args.focus_size=[args.initial_points(2, 2)-args.initial_points(2, 1)+1 args.initial_points(1, 2)-args.initial_points(1, 1)+1];
    args.center=floor(mean(args.initial_points, 2));
elseif size(args.initial_points, 2)==4
    args.center=floor(mean(args.initial_points, 2));
    pt_mean=args.initial_points-args.center*ones(1, 4);
    if isempty(args.focus_size)
        args.focus_size=mean(abs(pt_mean), 2)*2;
        args.focus_size=floor([args.focus_size(2) args.focus_size(1)]);
    end
    focus_center=floor([1+args.focus_size(2) 1+args.focus_size(1)]/2);
    XData=[1-focus_center(1) args.focus_size(2)-focus_center(1)];
    YData=[1-focus_center(2) args.focus_size(1)-focus_center(2)];
    X=[XData(1) XData(2) XData(2) XData(1);...
       YData(1) YData(1) YData(2) YData(2)];
    args.initial_tfm_matrix=compute_homography(X, floor(pt_mean));
end